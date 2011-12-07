module Main ( main ) where

import Data.Map ( mapKeys )
import System.FilePath ( (<.>) )
import Test.HUnit ( assertEqual )

import Data.LLVM
import Data.LLVM.CallGraph
import Data.LLVM.Parse
import Data.LLVM.Analysis.Escape
import Data.LLVM.Analysis.PointsTo
import Data.LLVM.Analysis.PointsTo.TrivialFunction
import Data.LLVM.Testing

import Foreign.Inference.Array

main :: IO ()
main = testAgainstExpected bcParser testDescriptors
  where
    bcParser = parseLLVMFile defaultParserOptions

testDescriptors = [ TestDescriptor { testPattern = "tests/arrays/*.c"
                                   , testExpectedMapping = (<.> "expected")
                                   , testResultBuilder = analyzeArrays
                                   , testResultComparator = assertEqual
                                   }
                  ]

analyzeArrays m = convertSummary $ identifyArrays cg er
  where
    pta = runPointsToAnalysis m
    cg = mkCallGraph m pta []
    er = runEscapeAnalysis m cg

convertSummary = mapKeys argToString
argToString a = (show (functionName f), show (argumentName a))
  where
    f = argumentFunction a