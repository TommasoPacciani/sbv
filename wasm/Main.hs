module Main (main) where

import Control.Exception (try, SomeException)
import System.IO
import Data.SBV

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  hSetBuffering stderr NoBuffering
  putStrLn "SBV in the browser: pristine native engine -> wasm32-wasi Boolector"
  r <- try body :: IO (Either SomeException ())
  case r of
    Left e  -> putStrLn ("EXC: " ++ show e)
    Right _ -> putStrLn "[all queries done]"

body :: IO ()
body = do
  r1 <- satWith   boolector $ \x -> x * 3 .== (1 :: SWord8)
  putStrLn $ "sat   (x * 3 == 1 :: SWord8):  " ++ show r1
  r2 <- proveWith boolector $ \x -> x + 1 ./= (x :: SWord8)
  putStrLn $ "prove (x + 1 /= x :: SWord8):  " ++ show r2
