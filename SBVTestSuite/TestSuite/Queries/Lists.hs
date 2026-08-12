-----------------------------------------------------------------------------
-- |
-- Module    : TestSuite.Queries.Lists
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- Testing a few lists
-----------------------------------------------------------------------------

{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE QuasiQuotes         #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module TestSuite.Queries.Lists (tests)  where

import Data.SBV
import Data.SBV.Control
import qualified Data.SBV.List as List

import Control.Monad (unless)

import Utils.SBVTestFramework

-- Test suite
tests :: TestTree
tests =
  testGroup "Basics.QueryLists"
    [ goldenCapturedIO "query_Lists1" $ testQuery queryLists1
    , testCase "incremental-defined-folds" $
        runSMTWith z3 $ query $ do
          values <- freshVar_ :: Query (SList Integer)
          let trueUF = uninterpret "incrementalFoldUF" :: SInteger -> SInteger
              nested = smtFunction "incrementalFoldNested" (\x -> trueUF x + 1)
              firstStep :: Closure SInteger (SInteger -> SInteger -> SInteger)
              firstStep = Closure { closureEnv = 10
                                  , closureFun = \environment accumulated element ->
                                      accumulated + nested (environment + element)
                                  }
              secondStep :: Closure SInteger (SInteger -> SInteger -> SInteger)
              secondStep = Closure { closureEnv = 3
                                   , closureFun = \environment accumulated element ->
                                       2 * accumulated + environment + element
                                   }
              firstFold  = List.foldl firstStep  0 values
              secondFold = List.foldl secondStep 1 values

          constrain $    values     .== literal [1, 2 :: Integer]
                    .&& firstFold  .== 23
                    .&& secondFold .== 17

          firstCheck <- checkSat
          unless (firstCheck == Sat) $
            error $ "Expected first incremental fold check to be Sat, got: " ++ show firstCheck

          firstModel <- (,,) <$> getValue values <*> getValue firstFold <*> getValue secondFold
          unless (firstModel == ([1, 2], 23, 17)) $
            error $ "Unexpected first incremental fold model: " ++ show firstModel

          let reusedFirst = List.foldl firstStep 0 values
              thirdStep :: Closure SInteger (SInteger -> SInteger -> SInteger)
              thirdStep = Closure { closureEnv = 4
                                  , closureFun = \environment accumulated element ->
                                      accumulated + environment * element
                                  }
              thirdFold = List.foldl thirdStep 5 values

          constrain $ reusedFirst .== 23 .&& thirdFold .== 17

          secondCheck <- checkSat
          unless (secondCheck == Sat) $
            error $ "Expected second incremental fold check to be Sat, got: " ++ show secondCheck

          secondModel <- (,) <$> getValue reusedFirst <*> getValue thirdFold
          unless (secondModel == (23, 17)) $
            error $ "Unexpected second incremental fold model: " ++ show secondModel

    ]

testQuery :: Show a => Symbolic a -> FilePath -> IO ()
testQuery t rf = do r <- runSMTWith defaultSMTCfg{verbose=True, redirectVerbose=Just rf} t
                    appendFile rf ("\nFINAL OUTPUT:\n" ++ show r ++ "\n")

queryLists1 :: Symbolic [Integer]
queryLists1 = do a :: SList Integer <- sList "a"

                 constrain $ a .== [sEnum|1..5|]

                 query $ do _ <- checkSat

                            av <- getValue a

                            if av == [1..5]
                               then return av
                               else error $ "Didn't expect this: " ++ show av
