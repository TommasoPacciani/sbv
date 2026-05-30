-----------------------------------------------------------------------------
-- |
-- Module    : TestSuite.Wasm.SafeWithPaths
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- Property test for the browser-path source-location path reporting used by
-- 'Data.SBV.safeWith' (Requirement 11.3, design Property 12).
--
-- On the native path 'Data.SBV.safeWith' computes a current working directory
-- and relativizes each source-location file path against it; on the browser
-- (WASM) path there is no operating-system current working directory, so
-- 'getCurrentDirectory' is skipped and each 'Data.SBV.SafeResult' reports its
-- source-location path /unmodified/. Both CPP branches of 'safeWith' route
-- their path reporting through the single shared helper
-- 'Data.SBV.Internals.mkRelativeFor': the browser branch uses
-- @'mkRelativeFor' 'Nothing'@ (identity), the native branch uses
-- @'mkRelativeFor' ('Just' cwd)@ (relativization). This module exercises that
-- shared helper directly so the browser-path contract is checked on a stock
-- native GHC without needing the @-DSBV_WASM@ build.
-----------------------------------------------------------------------------

{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module TestSuite.Wasm.SafeWithPaths (tests) where

import Data.List (intercalate, isPrefixOf)

import Data.SBV.Internals (mkRelativeFor)

import Utils.SBVTestFramework

import qualified Test.Tasty.QuickCheck as QC

-- | Test suite.
tests :: TestTree
tests = testGroup "Wasm.SafeWithPaths" [ safeWithReportsPathsUnmodified ]

-- | A current-working-directory prefix, always ending in @\"/\"@, exactly as
-- native 'safeWith' forms it (@(++ \"/\") \<$\> getCurrentDirectory@).
newtype Cwd = Cwd FilePath deriving Show

-- | One generated scenario: a current working directory together with a batch
-- ("set") of source-location file paths. Some of the paths deliberately begin
-- with the @cwd@ (so native relativization /would/ strip the prefix) and some
-- are unrelated (so even native leaves them unchanged). The browser path must
-- report /every/ one of them unmodified.
data Scenario = Scenario Cwd [FilePath] deriving Show

-- | A single non-empty path segment containing no @\'/\'@.
genSegment :: QC.Gen String
genSegment = do n <- QC.choose (1, 6)
                QC.vectorOf n (QC.elements (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ "_-."))

-- | An absolute directory path (leading @\'/\'@, no trailing slash).
genDir :: QC.Gen FilePath
genDir = do n    <- QC.choose (1, 4)
            segs <- QC.vectorOf n genSegment
            pure ('/' : intercalate "/" segs)

-- | A relative source-location tail, e.g. @\"src/Foo/Bar.hs\"@.
genRelPath :: QC.Gen FilePath
genRelPath = do n    <- QC.choose (1, 4)
                segs <- QC.vectorOf n genSegment
                pure (intercalate "/" segs)

-- | Generate a scenario. The @cwd@ ends in @\"/\"@; each path is either
-- @cwd ++ rel@ (shares the prefix) or an unrelated absolute path.
genScenario :: QC.Gen Scenario
genScenario = do dir <- genDir
                 let cwd = dir ++ "/"
                 k     <- QC.choose (1, 8)
                 paths <- QC.vectorOf k (genPath cwd)
                 pure (Scenario (Cwd cwd) paths)
  where genPath cwd = QC.oneof [ (cwd ++) <$> genRelPath        -- shares the cwd prefix
                               , genUnrelated cwd               -- does not share it
                               ]
        -- Build an absolute path and make sure it is NOT prefixed by cwd.
        genUnrelated cwd = do p <- (++) <$> genDir <*> (('/' :) <$> genRelPath)
                              pure $ if cwd `isPrefixOf` p then '_' : p else p

-- Feature: sbv-browser-wasm-backend, Property 12: safeWith reports source-location paths unmodified
safeWithReportsPathsUnmodified :: TestTree
safeWithReportsPathsUnmodified =
    QC.testProperty "Property 12: safeWith reports source-location paths unmodified" $
      QC.withNumTests 500 $
        QC.forAll genScenario $ \(Scenario (Cwd cwd) paths) ->
          QC.conjoin [ checkPath cwd p | p <- paths ]

-- | The per-path contract. @'mkRelativeFor' 'Nothing'@ models the browser path
-- (no current working directory); @'mkRelativeFor' ('Just' cwd)@ models the
-- native path (relativize against @cwd@).
checkPath :: FilePath -> FilePath -> QC.Property
checkPath cwd p = QC.counterexample ("cwd: " ++ show cwd ++ ", path: " ++ show p)
                $ QC.conjoin (unmodified : distinguishes)
  where browser = mkRelativeFor Nothing
        native  = mkRelativeFor (Just cwd)

        -- (1) The browser path reports every source-location path UNMODIFIED.
        unmodified :: QC.Property
        unmodified = browser p QC.=== p

        -- (2) When a path begins with the cwd the browser path still does NOT
        --     strip it (it stays identical to the original), whereas the native
        --     path DOES strip the prefix -- proving the browser path neither
        --     relativizes nor consults a current working directory. For paths
        --     that do not share the prefix even native leaves them unchanged.
        distinguishes :: [QC.Property]
        distinguishes
          | cwd `isPrefixOf` p = [ native  p QC.=== drop (length cwd) p
                                 , browser p QC.=/= native p
                                 ]
          | True               = [ native  p QC.=== p ]
