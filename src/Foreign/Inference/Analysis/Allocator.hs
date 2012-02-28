{-# LANGUAGE ViewPatterns #-}
module Foreign.Inference.Analysis.Allocator (
  AllocatorSummary,
  identifyAllocators,
  -- * Testing
  allocatorSummaryToTestFormat
  ) where

import Control.Monad.RWS.Strict
import Data.Map ( Map )
import qualified Data.Map as M

import Data.LLVM
import Data.LLVM.Analysis.CallGraph
import Data.LLVM.Analysis.CallGraphSCCTraversal

import Foreign.Inference.Diagnostics
import Foreign.Inference.Interface
import Foreign.Inference.Analysis.Escape
-- import Foreign.Inference.Analysis.Finalize
import Foreign.Inference.Internal.FlattenValue

-- import Debug.Trace
-- debug = flip trace

type SummaryType = Map Function (Maybe String)
data AllocatorSummary = AS SummaryType

data AllocatorData =
  AllocatorData { dependencySummary :: DependencySummary
                , escapeSummary :: EscapeSummary
                }

type AnalysisMonad = RWS AllocatorData Diagnostics ()

instance SummarizeModule AllocatorSummary where
  summarizeArgument _ _ = []
  summarizeFunction f (AS summ) =
    case M.lookup f summ of
      Nothing -> []
      Just (Just fin) -> [FAAllocator fin]
      Just Nothing -> [FAAllocator ""]

-- FIXME: Two extensions are required:
--
--  * Support looking at the called functions in the return value and
--    see if they are global funcptrs that have a default value.
--    Check to see if that default value is an allocator.  It could be
--    replaced with something that is not, but it is a clear
--    indication of intent if it is an allocator, and we will consider
--    that sufficient.  Many libraries use replacable allocators.
--
--  * Support allocators where a chunk of memory is allocated and then
--    some pointer into the slab is returned, instead of just the
--    pointer itself.  Relevant for at least glpk and jansson (plus
--    others).

identifyAllocators :: DependencySummary
                      -> EscapeSummary
                      -> CallGraph
                      -> (AllocatorSummary, Diagnostics)
identifyAllocators ds es cg = (AS summ, diags)
  where
    analysis = callGraphSCCTraversal cg allocatorAnalysis M.empty
    readOnlyData = AllocatorData ds es
    (summ, diags) = evalRWS analysis readOnlyData ()

-- | If the function returns a pointer, it is a candidate for an
-- allocator.  We do not concern ourselves with functions that may
-- unwind or call exit on error - these can also be allocators.
allocatorAnalysis :: Function -> SummaryType -> AnalysisMonad SummaryType
allocatorAnalysis f summ =
  case exitInst of
    RetInst { retInstValue = Just rv } ->
      case valueType rv of
        -- The function always returns a pointer
        TypePointer _ _ -> checkReturn f rv summ
        -- Non-pointer return, ignore
        _ -> return summ
    -- Returns void
    _ -> return summ
  where
    exitInst = functionExitInstruction f

-- | If the return value is always one of:
--
--  * NULL
--
--  * The result of an allocator (and does not escape)
--
-- then f is an allocator.  If there is a unique finalizer for the
-- same type, associate it with this allocator.
checkReturn :: Function -> Value -> SummaryType -> AnalysisMonad SummaryType
checkReturn f rv summ =
  case null nonNullRvs of
    -- Always returns NULL, not an allocator
    True -> return summ
    False -> do
      valid <- mapM (isAllocatedWithoutEscape summ) nonNullRvs
      case and valid of
        False -> return summ
        True -> return $ M.insert f Nothing summ
  where
    rvs = flattenValue rv
    -- Here, drop all NULLs that are being returned since that is
    -- okay.  Also filter out Phi nodes (since we flattened the phi
    -- node to all of the values it could represent, but that list
    -- contains the phi node itself).
    nonNullRvs = filter isNotNull $ filter isNotPhi rvs

-- | Return True if the given Value is the result of a call to an
-- allocator AND does not escape.
isAllocatedWithoutEscape :: SummaryType -> Value -> AnalysisMonad Bool
isAllocatedWithoutEscape summ rv = do
  allocatorInsts <- case valueContent' rv of
    InstructionC i@CallInst { callFunction = f } ->
      checkFunctionIsAllocator f summ i
    InstructionC i@InvokeInst { invokeFunction = f } ->
      checkFunctionIsAllocator f summ i
    _ -> return []
  -- If there are no values to check for escaping, this is not an
  -- allocator.  If there are values, none may escape.
  case null allocatorInsts of
    True -> return False
    False -> noneEscape allocatorInsts

checkFunctionIsAllocator :: Value -> SummaryType -> Instruction -> AnalysisMonad [Instruction]
checkFunctionIsAllocator v summ i =
  case valueContent' v of
    FunctionC f ->
      case M.lookup f summ of
        Nothing -> return []
        Just _ -> return [i]
    ExternalFunctionC f -> do
      depSumm <- asks dependencySummary
      case lookupFunctionSummary depSumm f of
        Nothing -> return []
        Just annots ->
          case any isAllocatorAnnot annots of
            False -> return []
            True -> return [i]
    InstructionC LoadInst { loadAddress = (valueContent' ->
      GlobalVariableC GlobalVariable { globalVariableInitializer = Just val0 })} ->
      checkFunctionIsAllocator val0 summ i
    -- Indirect call
    _ -> return []

noneEscape :: [Instruction] -> AnalysisMonad Bool
noneEscape is = do
  escSumm <- asks escapeSummary
  return $! not (any (instructionEscapes escSumm) is)

-- Helpers

isAllocatorAnnot :: FuncAnnotation -> Bool
isAllocatorAnnot (FAAllocator _) = True
isAllocatorAnnot _ = False

isNotNull :: Value -> Bool
isNotNull v =
  case valueContent v of
    ConstantC ConstantPointerNull {} -> False
    _ -> True

isNotPhi :: Value -> Bool
isNotPhi v =
  case valueContent' v of
    InstructionC PhiNode {} -> False
    _ -> True

-- Testing

-- | Convert an Allocator summary to a format more suitable for
-- testing
allocatorSummaryToTestFormat :: AllocatorSummary -> Map String (Maybe String)
allocatorSummaryToTestFormat (AS s) = M.mapKeys (show . functionName) s