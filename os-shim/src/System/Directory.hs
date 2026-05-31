-- | Out-of-tree replacement for the slice of "System.Directory" SBV uses. On the
-- browser path there is no real filesystem search: @findExecutable@ always
-- succeeds with a virtual path that the JS host maps to a solver wasm, and the
-- code-generation helpers (unused at solve time) are inert stubs.
module System.Directory
  ( findExecutable
  , getCurrentDirectory
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  ) where

findExecutable :: String -> IO (Maybe FilePath)
findExecutable nm = pure (Just ("/bin/" ++ nm))

getCurrentDirectory :: IO FilePath
getCurrentDirectory = pure "/"

createDirectoryIfMissing :: Bool -> FilePath -> IO ()
createDirectoryIfMissing _ _ = pure ()

doesDirectoryExist :: FilePath -> IO Bool
doesDirectoryExist _ = pure False

doesFileExist :: FilePath -> IO Bool
doesFileExist _ = pure False
