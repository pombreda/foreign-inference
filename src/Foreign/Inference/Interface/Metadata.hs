{-# LANGUAGE TemplateHaskell #-}
module Foreign.Inference.Interface.Metadata (
  moduleInterfaceEnumerations,
  moduleInterfaceStructTypes,
  paramMetaUnsigned,
  functionReturnMetaUnsigned,
  -- * Helper
  sanitizeStructName
  ) where

import Control.Arrow ( (&&&) )
import qualified Data.ByteString.Char8 as SBS
import Data.HashMap.Strict ( HashMap )
import qualified Data.HashMap.Strict as M
import qualified Data.HashSet as HS
import qualified Data.Set as S
import Data.List ( stripPrefix )
import Data.Maybe ( catMaybes, mapMaybe )
import Debug.Trace.LocationTH

import LLVM.Analysis

import Data.Graph.Interface
import Data.Graph.PatriciaTree
import Data.Graph.Algorithms.Matching.DFS

import Foreign.Inference.Internal.TypeUnification
import Foreign.Inference.Interface.Types

-- | Collect all of the enumerations used in the external interface of
-- a Module by inspecting metadata.
moduleInterfaceEnumerations :: Module -> [CEnum]
moduleInterfaceEnumerations =
  S.toList . S.fromList . foldr extractInterfaceEnumTypes [] . moduleDefinedFunctions

moduleInterfaceStructTypes :: Module -> [CType]
moduleInterfaceStructTypes m = opaqueTypes ++ concreteTypes
  where
    defFuncs = moduleDefinedFunctions m
    interfaceTypeMap = foldr extractInterfaceStructTypes M.empty defFuncs
    (unifiedTypes, ununifiedTypes) = unifyTypes (M.keys interfaceTypeMap)
    unifiedMDTypes = map (findTypeMD interfaceTypeMap) unifiedTypes
    sortedUnifiedMDTypes = typeSort unifiedMDTypes
    concreteTypes = mapMaybe metadataStructTypeToCType sortedUnifiedMDTypes

    uniqueOpaqueTypeNames = HS.toList $ HS.fromList $ map structTypeName ununifiedTypes
    opaqueTypes = map toOpaqueCType uniqueOpaqueTypeNames

-- | Collect all of the struct types (along with their metadata) used
-- in the external interface of a Module.
-- moduleInterfaceStructTypes :: Module -> HashMap Type Metadata
-- moduleInterfaceStructTypes =
--   foldr extractInterfaceStructTypes M.empty . moduleDefinedFunctions

structTypeName :: Type -> String
structTypeName (TypeStruct (Just name) _ _) = sanitizeStructName name
structTypeName t = $failure ("Expected struct type: " ++ show t)

toOpaqueCType :: String -> CType
toOpaqueCType name = CStruct name []


-- | Match up a type with its metadata
findTypeMD :: HashMap Type Metadata -> Type -> (Type, Metadata)
findTypeMD interfaceTypeMap t =
  case M.lookup t interfaceTypeMap of
    Nothing -> $failure ("No metadata found for type: " ++ show t)
    Just md -> (t, md)


extractInterfaceEnumTypes :: Function -> [CEnum] -> [CEnum]
extractInterfaceEnumTypes f acc =
  foldr collectEnums acc typeMds
  where
    retMd = functionReturnTypeMetadata f
    argMds = map paramTypeMetadata (functionParameters f)
    typeMds = catMaybes $ retMd : argMds

collectEnums :: Metadata -> [CEnum] -> [CEnum]
collectEnums MetaDWDerivedType { metaDerivedTypeParent = Just parent
                               } acc =
  collectEnums parent acc
collectEnums MetaDWCompositeType { metaCompositeTypeTag = DW_TAG_enumeration_type
                                 , metaCompositeTypeName = bsname
                                 , metaCompositeTypeMembers = Just (MetadataList _ enums)
                                 } acc =
  CEnum { enumName = SBS.unpack bsname
        , enumValues = mapMaybe toEnumeratorValue enums
        } : acc
collectEnums _ acc = acc

toEnumeratorValue :: Maybe Metadata -> Maybe (String, Int)
toEnumeratorValue (Just MetaDWEnumerator { metaEnumeratorName = ename
                                         , metaEnumeratorValue = eval
                                         }) =
  Just (SBS.unpack ename, fromIntegral eval)
toEnumeratorValue _ = Nothing

extractInterfaceStructTypes :: Function -> HashMap Type Metadata -> HashMap Type Metadata
extractInterfaceStructTypes f m =
  foldr addTypeMdMapping m (mapMaybe isStructType typeMds)
  where
    TypeFunction rt _ _ = functionType f
    retMd = functionReturnTypeMetadata f
    argMds = map (argumentType &&& paramTypeMetadata) (functionParameters f)
    typeMds = (rt, retMd) : argMds
    addTypeMdMapping (llvmType, mdType) mdMap =
      case mdType of
        Nothing -> mdMap
        Just md -> M.insert llvmType md mdMap

isStructType :: (Type, Maybe Metadata) -> Maybe (Type, Maybe Metadata)
isStructType (t@(TypeStruct _ _ _),
              Just MetaDWDerivedType { metaDerivedTypeTag = DW_TAG_typedef
                                , metaDerivedTypeParent = parent
                                }) =
  isStructType (t, parent)
isStructType (t@(TypeStruct _ _ _), a) = Just (t, a)
isStructType (TypePointer inner _,
              Just MetaDWDerivedType { metaDerivedTypeTag = DW_TAG_pointer_type
                                , metaDerivedTypeParent = parent
                                }) =
  isStructType (inner, parent)
isStructType (t@(TypePointer _ _),
              Just MetaDWDerivedType { metaDerivedTypeTag = DW_TAG_typedef
                                , metaDerivedTypeParent = parent}) =
  isStructType (t, parent)
isStructType _ = Nothing

sanitizeStructName :: String -> String
sanitizeStructName name = takeWhile (/= '.') name'
  where
    name' = case stripPrefix "struct." name of
      Nothing ->
        case stripPrefix "union." name of
          Nothing -> name
          Just x -> x
      Just x -> x

metadataStructTypeToCType :: (Type, Metadata) -> Maybe CType
metadataStructTypeToCType (TypeStruct (Just name) members _,
                           MetaDWCompositeType { metaCompositeTypeMembers =
                                                    Just (MetadataList _ cmembers)
                                               }) = do
  let memberTypes = zip members cmembers
  mtys <- mapM trNameAndType memberTypes
  return (CStruct (sanitizeStructName name) mtys)
  where
    trNameAndType (llvmType, Just MetaDWDerivedType { metaDerivedTypeName = memberName
                                               }) = do
      realType <- structMemberToCType llvmType
      return (SBS.unpack memberName, realType)
    trNameAndType _ = Nothing
-- If there were no members in the metadata, this is an opaque type
metadataStructTypeToCType (TypeStruct (Just name) _ _, _) =
  return $! CStruct (sanitizeStructName name) []
metadataStructTypeToCType t =
  $failure ("Unexpected non-struct metadata: " ++ show t)

structMemberToCType :: Type -> Maybe CType
structMemberToCType t = case t of
  TypeInteger i -> return $! CInt i
  TypeFloat -> return CFloat
  TypeDouble -> return CDouble
  TypeArray n t' -> do
    tt <- structMemberToCType t'
    return $! CArray tt n
  TypeFunction r ts _ -> do
    rt <- structMemberToCType r
    tts <- mapM structMemberToCType ts
    return $! CFunction rt tts
  TypePointer t' _ -> do
    tt <- structMemberToCType t'
    return $! CPointer tt
  TypeStruct (Just n) _ _ ->
    let name' = sanitizeStructName n
    in return $! CStruct name' []
  TypeStruct Nothing ts _ -> do
    tts <- mapM structMemberToCType ts
    return $! CAnonStruct tts
  TypeVoid -> return $! CVoid -- Nothing
  TypeFP128 -> return $! CArray (CInt 8) 16
  -- Fake an 80 bit floating point number with an array of 10 bytes
  TypeX86FP80 -> return $! CArray (CInt 8) 10
  TypePPCFP128 -> return $! CArray (CInt 8) 16
  TypeX86MMX -> Nothing
  TypeLabel -> Nothing
  TypeMetadata -> Nothing
  TypeVector _ _ -> Nothing

paramMetaUnsigned :: Argument -> Bool
paramMetaUnsigned a =
  case argumentMetadata a of
    [] -> False
    [MetaDWLocal { metaLocalType = Just mt }] -> do
      case mt of
        MetaDWBaseType { metaBaseTypeEncoding = DW_ATE_unsigned } -> True
        MetaDWDerivedType { metaDerivedTypeParent = Just baseType } ->
          case baseType of
            MetaDWBaseType { metaBaseTypeEncoding = DW_ATE_unsigned } -> True
            _ -> False
        _ -> False
    _ -> False


paramTypeMetadata :: Argument -> Maybe Metadata
paramTypeMetadata a =
  case argumentMetadata a of
    [] -> Nothing
    [MetaDWLocal { metaLocalType = mt }] -> mt
    _ -> Nothing

functionReturnMetaUnsigned :: Function -> Bool
functionReturnMetaUnsigned f =
  case functionMetadata f of
    [] -> False
    [MetaDWSubprogram { metaSubprogramType = Just ftype }] ->
      case ftype of
        MetaDWCompositeType { metaCompositeTypeMembers = Just ms } ->
          case ms of
            MetadataList _ (Just rt : _) ->
              case rt of
                MetaDWDerivedType { metaDerivedTypeParent = Just baseType } ->
                  case baseType of
                    MetaDWBaseType { metaBaseTypeEncoding = DW_ATE_unsigned } -> True
                    _ -> False
                MetaDWBaseType { metaBaseTypeEncoding = DW_ATE_unsigned } -> True
                _ -> False
            _ -> False
        _ -> False
    _ -> False

functionReturnTypeMetadata :: Function -> Maybe Metadata
functionReturnTypeMetadata f =
  case functionMetadata f of
    [] -> Nothing
    [MetaDWSubprogram { metaSubprogramType = Just ftype }] ->
      case ftype of
        MetaDWCompositeType { metaCompositeTypeMembers = Just ms } ->
          case ms of
            MetadataList _ (rt : _) -> rt
            _ -> Nothing
        _ -> Nothing
    _ -> Nothing

type TypeGraph = Gr (Type, Metadata) ()

-- | All of the components of a type that are stored by-value must be
-- defined before that type can be defined.  This is a topological
-- ordering captured by this graph-based sort.
typeSort :: [(Type, Metadata)] -> [(Type, Metadata)]
typeSort ts = reverse $ topsort' g
  where
    g :: TypeGraph
    g = mkGraph ns es

    toNodeMap = M.fromList (zip (map fst ts) [0..])
    ns = map (\(ix, t) -> LNode ix t) (zip [0..] ts)
    es = concatMap toEdges ts
    toEdges (t@(TypeStruct _ members _), _) =
      case M.lookup t toNodeMap of
        Nothing -> $failure ("Expected node id for type: " ++ show t)
        Just srcid -> mapMaybe (toEdge srcid) members
    toEdges _ = []
    toEdge srcid t = do
      dstid <- M.lookup t toNodeMap
      return $! LEdge (Edge srcid dstid) ()
