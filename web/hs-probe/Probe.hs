module Main (main) where

import Control.Exception (try, SomeException)
import GHC.IO.Handle.FD  (fdToHandle')
import GHC.IO.Device      (IODeviceType(Stream))
import System.IO

foreign import javascript unsafe "spawnEcho()" js_spawnEcho :: IO Int

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  r <- try body :: IO (Either SomeException ())
  case r of
    Left e  -> putStrLn ("EXC:" ++ show e)
    Right _ -> putStrLn "DONE"

body :: IO ()
body = do
  base <- js_spawnEcho
  hIn  <- fdToHandle' (fromIntegral base)       (Just Stream) False "solver-in"  WriteMode False
  hOut <- fdToHandle' (fromIntegral (base + 1)) (Just Stream) False "solver-out" ReadMode  False
  hSetBuffering hIn  LineBuffering
  hSetBuffering hOut LineBuffering
  hPutStrLn hIn "hello-from-haskell"
  hFlush hIn
  l <- hGetLine hOut
  putStrLn ("GOT:" ++ l)
