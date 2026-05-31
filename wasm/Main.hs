module Main (main) where

import Control.Exception (try, SomeException)
import System.IO
import Data.SBV
import Data.SBV.Control

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  hSetBuffering stderr NoBuffering
  putStrLn "SBV in the browser: pristine native engine -> wasm32-wasi Boolector + z3"
  r <- try body :: IO (Either SomeException ())
  case r of
    Left e  -> putStrLn ("EXC: " ++ show e)
    Right _ -> putStrLn "[all queries done]"

body :: IO ()
body = do
  -- Boolector: bit-vector queries (existing)
  r1 <- satWith   boolector $ \x -> x * 3 .== (1 :: SWord8)
  putStrLn $ "sat   (x * 3 == 1 :: SWord8):  " ++ show r1
  r2 <- proveWith boolector $ \x -> x + 1 ./= (x :: SWord8)
  putStrLn $ "prove (x + 1 /= x :: SWord8):  " ++ show r2

  -- Z3: integer arithmetic
  r3 <- satWith z3 $ \x -> x * 3 .== (12 :: SInteger)
  putStrLn $ "sat   (x * 3 == 12 :: SInteger): " ++ show r3

  -- Z3: real arithmetic
  r4 <- satWith z3 $ \r -> r * 2 .== (5 :: SReal)
  putStrLn $ "sat   (r * 2 == 5 :: SReal):     " ++ show r4

  -- Z3: floating-point
  r5 <- satWith z3 $ \d -> d + 1.0 .== (3.5 :: SDouble)
  putStrLn $ "sat   (d + 1.0 == 3.5 :: SDouble): " ++ show r5

  -- Z3: prove
  r6 <- proveWith z3 $ \x -> x + 0 .== (x :: SInteger)
  putStrLn $ "prove (x + 0 == x :: SInteger): " ++ show r6

  -- Z3: incremental query mode (push/pop, repeated check-sat, get-value)
  rq <- runSMTWith z3 $ do
          [x, y] <- sIntegers ["x", "y"]
          constrain $ x + y .== 10
          query $ do
            push 1
            constrain $ x .== 3
            cs1 <- checkSat
            v1  <- case cs1 of { Sat -> show <$> ((,) <$> getValue x <*> getValue y); _ -> pure (show cs1) }
            pop 1
            constrain $ x .== 7
            cs2 <- checkSat
            v2  <- case cs2 of { Sat -> show <$> getValue x; _ -> pure (show cs2) }
            pure (v1 ++ " then x=7 -> " ++ v2)
  putStrLn $ "query (incremental push/pop): " ++ rq
