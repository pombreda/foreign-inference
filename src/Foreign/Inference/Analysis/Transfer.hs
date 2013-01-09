{-# LANGUAGE DeriveGeneric, TemplateHaskell, ViewPatterns #-}
{-# LANGUAGE RankNTypes #-}
module Foreign.Inference.Analysis.Transfer (
  TransferSummary,
  identifyTransfers,
  -- * Testing
  transferSummaryToTestFormat
  ) where

import GHC.Generics ( Generic )

import Control.DeepSeq
import Control.DeepSeq.Generics ( genericRnf )
import Control.Lens ( (%~), (.~), (^.), Simple, makeLenses )
import Control.Monad ( foldM )
import qualified Data.Foldable as F
import Data.Map ( Map )
import qualified Data.Map as M
import Data.Maybe ( fromMaybe )
import Data.Monoid
import Data.Set ( Set )
import qualified Data.Set as S

import LLVM.Analysis
import LLVM.Analysis.AccessPath
import LLVM.Analysis.CallGraph
import LLVM.Analysis.CallGraphSCCTraversal

import Foreign.Inference.AnalysisMonad
import Foreign.Inference.Diagnostics
import Foreign.Inference.Interface
import Foreign.Inference.Analysis.Finalize
import Foreign.Inference.Analysis.IndirectCallResolver
import Foreign.Inference.Analysis.Util.CalleeFold

import Debug.Trace
debug = flip trace

data TransferSummary = TransferSummary {
  _transferArguments :: Set Argument,
  _transferDiagnostics :: Diagnostics
  }
  deriving (Generic)

$(makeLenses ''TransferSummary)

instance Eq TransferSummary where
  (TransferSummary _ _) == (TransferSummary _ _) = True

instance Monoid TransferSummary where
  mempty = TransferSummary mempty mempty
  mappend (TransferSummary t1 d1) (TransferSummary t2 d2) =
    TransferSummary (t1 `mappend` t2) (d1 `mappend` d2)

instance NFData TransferSummary where
   rnf = genericRnf

instance HasDiagnostics TransferSummary where
  diagnosticLens = transferDiagnostics

instance SummarizeModule TransferSummary where
  summarizeFunction _ _ = []
  summarizeArgument a (TransferSummary t _)
    | S.member a t = [(PATransfer, [])]
    | otherwise = []


-- Algorithm:
--
-- In one pass, determine all of the *structure fields* that are
-- passed to a finalizer.  These are *owned* fields.  The shape
-- analysis bit will come later (to find finalized things that are
-- stored in "container-likes")
--
-- Maybe we can remove the need for some shape analysis by looking at
-- dependence.
--
-- > void foo(bar * baz) {
-- >   while(hasNext(baz->quux)) {
-- >     q = next(&baz->quux);
-- >     free_quux(q);
-- >   }
-- > }
--
-- In a second pass, find all of the arguments that flow into those
-- owned fields and mark them as Transferred.  Again, this will need
-- to be aware of the pseudo-shape analysis results (i.e., this
-- parameter ends up linked into this data structure via this field
-- after this call).  This pass will need to reach a fixed point.
--
-- At the end of the day, this will be simpler than the escape
-- analysis since we do not need to track fields of arguments or
-- anything of that form.
--
-- This could additionally depend on the ref count analysis and just
-- strip off transfer tags from ref counted types.

-- FIXME this really needs a fixedpoint!

identifyTransfers :: (HasFunction funcLike)
                     => [funcLike]
                     -> CallGraph
                     -> DependencySummary
                     -> IndirectCallSummary
                     -> compositeSummary
                     -> Simple Lens compositeSummary FinalizerSummary
                     -> Simple Lens compositeSummary TransferSummary
                     -> compositeSummary
identifyTransfers funcLikes cg ds pta p1res flens tlens =
  (tlens .~ res) p1res
  where
    res = runAnalysis a ds () ()
    finSumm = p1res ^. flens
    trSumm = p1res ^. tlens
    a = do
      ownedFields <- foldM (identifyOwnedFields cg pta finSumm) mempty funcLikes
      transferedParams <- foldM (identifyTransferredArguments pta ownedFields) trSumm funcLikes
--      return () `debug` show ownedFields
      return transferedParams

type Analysis = AnalysisMonad () ()

identifyTransferredArguments :: (HasFunction funcLike)
                                => IndirectCallSummary
                                -> Set AbstractAccessPath
                                -> TransferSummary
                                -> funcLike
                                -> Analysis TransferSummary
identifyTransferredArguments pta ownedFields trSumm flike =
  foldM checkTransfer trSumm (functionInstructions f)
  where
    f = getFunction flike
    formals = functionParameters f
    checkTransfer s i =
      case i of
        StoreInst { storeValue = (valueContent' -> ArgumentC sv) }
          | sv `elem` formals -> return $ fromMaybe s $ do
            -- We don't extract the storeAddress above because the
            -- access path construction handles that
            acp <- accessPath i
            let absPath = abstractAccessPath acp
            case S.member absPath ownedFields of
              True -> return $! (transferArguments %~ S.insert sv) s
              False -> return s
          | otherwise -> return s
        CallInst { callFunction = callee, callArguments = (map fst -> args) } ->
          calleeArgumentFold argumentTransfer s pta callee args
        InvokeInst { invokeFunction = callee, invokeArguments = (map fst -> args) } ->
          calleeArgumentFold argumentTransfer s pta callee args
        _ -> return s

    argumentTransfer callee s (ix, (valueContent' -> ArgumentC arg)) = do
      annots <- lookupArgumentSummaryList s callee ix
      case PATransfer `elem` annots of
        False -> return s
        True -> return $ (transferArguments %~ S.insert arg) s
    argumentTransfer _ s _ = return s

isFinalizerContext :: (HasFunction funcLike)
                      => CallGraph
                      -> FinalizerSummary
                      -> funcLike
                      -> Analysis Bool
isFinalizerContext cg finSumm flike =
  mapM isFinalizer callers >>= return . or
  where
    f = getFunction flike
    callers = allFunctionCallers cg f
    isFinalizer callee =
      case valueContent' callee of
        FunctionC fn -> do
          let ixs = [0..length (functionParameters fn)]
          mapM (isFinalizerArg callee) ixs >>= return . or
        ExternalFunctionC ef -> do
          let ixs = [0..length (externalFunctionParameterTypes ef)]
          mapM (isFinalizerArg callee) ixs >>= return . or
        _ -> return False
    isFinalizerArg callee ix = do
      annots <- lookupArgumentSummaryList finSumm callee ix
      return $ PAFinalize `elem` annots

-- | Add any field passed to a known finalizer to the accumulated Set.
--
-- This will eventually need to incorporate shape analysis results.
-- It will also need to distinguish somehow between fields that are
-- finalized and elements of container fields that are finalized.
--
-- FIXME: Only check finalizers in functions that are finalizers (or
-- are called *by* finalizers).
identifyOwnedFields :: (HasFunction funcLike)
                       => CallGraph
                       -> IndirectCallSummary
                       -> FinalizerSummary
                       -> Set AbstractAccessPath
                       -> funcLike
                       -> Analysis (Set AbstractAccessPath)
identifyOwnedFields cg pta finSumm ownedFields funcLike = do
  isFin <- isFinalizerContext cg finSumm funcLike
  case isFin of
    True -> foldM checkFinalize ownedFields insts
    False -> return ownedFields
  where
    insts = functionInstructions (getFunction funcLike)
    checkFinalize acc i =
      case i of
        CallInst { callFunction = cf, callArguments = (map fst -> args) } ->
          calleeArgumentFold addFieldIfFinalized acc pta cf args
        InvokeInst { invokeFunction = cf, invokeArguments = (map fst -> args) } ->
          calleeArgumentFold addFieldIfFinalized acc pta cf args
        _ -> return acc

    addFieldIfFinalized target acc (ix, arg) = do
      annots <- lookupArgumentSummaryList finSumm target ix
      case PAFinalize `elem` annots of
        False -> return acc
        True ->
          case valueContent' arg of
            InstructionC i -> return $ fromMaybe acc $ do
              accPath <- accessPath i
              let absPath = abstractAccessPath accPath
              return $ S.insert absPath acc
            _ -> return acc


-- Testing


transferSummaryToTestFormat :: TransferSummary -> Map String (Set String)
transferSummaryToTestFormat (TransferSummary s _) =
  F.foldr convert mempty s
  where
    convert a m =
      let f = argumentFunction a
          k = show (functionName f)
          v = show (argumentName a)
      in M.insertWith S.union k (S.singleton v) m
