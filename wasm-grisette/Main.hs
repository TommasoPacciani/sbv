{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
module Main (main) where

import Grisette
import Grisette.Internal.Backend.Solving (runSBVIncremental)
import Grisette.Internal.Core.Data.Class.Solver (monadicSolverSolve)

-- The expression language from Grisette's `basic` example.
data Expr a where
  IntVal  :: SymInteger -> IntExpr
  BoolVal :: SymBool -> BoolExpr
  Add     :: IntUExpr -> IntUExpr -> IntExpr
  Mul     :: IntUExpr -> IntUExpr -> IntExpr
  BAnd    :: BoolUExpr -> BoolUExpr -> BoolExpr
  BOr     :: BoolUExpr -> BoolUExpr -> BoolExpr
  Eq      :: (BasicSymPrim a) => UExpr a -> UExpr a -> BoolExpr

type IntExpr   = Expr SymInteger
type BoolExpr  = Expr SymBool
type UExpr a   = Union (Expr a)
type IntUExpr  = UExpr SymInteger
type BoolUExpr = UExpr SymBool

makeGrisetteBasicADT ''Expr

eval :: Expr a -> a
eval (IntVal a)  = a
eval (BoolVal a) = a
eval (Add a b)   = eval .# a + eval .# b
eval (Mul a b)   = eval .# a * eval .# b
eval (BAnd a b)  = eval .# a .&& eval .# b
eval (BOr a b)   = eval .# a .|| eval .# b
eval (Eq a b)    = eval .# a .== eval .# b

-- | Out-of-tree synchronous one-shot solve. Runs the solver on the CALLING
-- thread via Grisette's incremental backend (runSMTWith ... $ query ...),
-- bypassing newSolver's forkIO/STM handle which traps on the single-threaded
-- wasm RTS. Drop-in for Grisette's `solve` for verification-style queries.
solveSync :: GrisetteSMTConfig -> SymBool -> IO (Either SolvingFailure Model)
solveSync cfg = runSBVIncremental cfg . monadicSolverSolve

verifyEquivalent :: (BasicSymPrim a) => Expr a -> Expr a -> IO ()
verifyEquivalent e1 e2 = do
  res <- solveSync z3 (eval e1 ./= eval e2)
  case res of
    Left Unsat -> putStrLn "  equivalent"
    Left err   -> putStrLn $ "  solver error: " ++ show err
    Right m    -> putStrLn $ "  NOT equivalent; counterexample: " ++ show m

aPlusB, bPlusA, aPlusA :: IntExpr
aPlusB = Add (intVal "a") (intVal "b")
bPlusA = Add (intVal "b") (intVal "a")
aPlusA = Add (intVal "a") (intVal "a")

main :: IO ()
main = do
  putStrLn "Grisette in the browser: expression-language equivalence verification"
  putStrLn "verify a+b === b+a (expect equivalent):"
  verifyEquivalent aPlusB bPlusA
  putStrLn "verify a+a === a+b (expect counterexample):"
  verifyEquivalent aPlusA aPlusB
  putStrLn "[done]"
