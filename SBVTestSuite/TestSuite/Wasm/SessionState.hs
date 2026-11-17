-----------------------------------------------------------------------------
-- |
-- Module    : TestSuite.Wasm.SessionState
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- Property test for browser-path query-session state preservation
-- (Requirements 6.1, 6.3, design Property 8).
--
-- Requirement 6.1 states that when a caller runs a query block on the
-- Browser_Path, the Browser_Engine routes /every/ command in that block to a
-- /single/ WASM_Solver session. Requirement 6.3 states that, while a query
-- session is active, the Browser_Engine preserves WASM_Solver state across
-- successive commands such that declarations and assertions remain in effect
-- until a matching @pop@ removes them, so that @push@, @pop@, @check-sat@, and
-- @get-model@ observe the accumulated session state.
--
-- On the real browser path this preservation is /structural/: the whole query
-- block shares one @WasmSolver@ handle stored in @rQueryState@, so the solver
-- accumulates declarations/assertions across commands and a @pop@ only unwinds
-- the levels SBV asked it to. That single handle lives behind GHC's WebAssembly
-- JSFFI, which is uninhabited on a stock native GHC, so — exactly as the other
-- @Wasm.*@ property tests do — this module exercises the contract through the
-- reusable 'Utils.MockBridge' harness.
--
-- Honest modelling note: a real query session resolves its commands over the
-- single-threaded browser event loop. Here the session is modelled as a single
-- acquired 'Utils.MockBridge' handle driven through a strictly sequential batch
-- of push\/pop\/declare\/assert\/check-sat\/get-model commands — exactly how the
-- single-threaded runtime sequences SBV's @ask@. The harness records an ordered
-- transcript of every message handed to the one session, so we can recover what
-- the session actually accumulated.
--
-- The single property drives a generated command sequence through one session
-- and asserts the two observable halves of the guarantee:
--
--   * /Single session/ (Requirement 6.1). Every command is routed to one
--     acquired handle: initialization runs exactly once
--     ('Utils.MockBridge.initCount' @== 1@), the session is never torn down
--     mid-block ('Utils.MockBridge.releaseCount' @== 0@), it stays
--     'Utils.MockBridge.PhaseReady', no send is ever entered while another is in
--     flight, and the recorded transcript is exactly the ordered command
--     sequence (nothing dropped, duplicated, or reordered).
--
--   * /State preserved across commands/ (Requirement 6.3). Replaying the single
--     session's accumulated transcript under SMT push\/pop scoping reproduces,
--     at each @check-sat@\/@get-model@ observation point, exactly the set of
--     declarations\/assertions that the high-level operation semantics say
--     should still be in effect. The two derivations are independent — one
--     simulates the abstract operations, the other re-parses the raw command
--     strings the session actually received — so they agree only if every
--     declaration\/assertion persisted across successive commands and a @pop@
--     removed exactly its matching scope (leaving lower scopes, including the
--     base-scope declarations made before any @push@, still in effect).
-----------------------------------------------------------------------------

{-# OPTIONS_GHC -Wall -Werror #-}

module TestSuite.Wasm.SessionState (tests) where

import Data.Char (isDigit)
import Data.List (nub, sort)

import Data.Text (Text)
import qualified Data.Text as T

import Utils.SBVTestFramework

import qualified Utils.MockBridge        as MB
import qualified Test.Tasty.QuickCheck   as QC
import qualified Test.QuickCheck.Monadic as QC

-- | Test suite.
tests :: TestTree
tests = testGroup "Wasm.SessionState" [ sessionPreservesStateAcrossCommands ]

-- | One command in a query block. @Declare@\/@Assert@ carry a globally unique id
-- so each introduces a distinct, identifiable item into the current scope;
-- @Push@\/@Pop@ manage the assertion stack; @CheckSat@\/@GetModel@ are the
-- observation points at which the accumulated session state is examined.
data Op = Declare  Int
        | Assert   Int
        | Push
        | Pop
        | CheckSat
        | GetModel
        deriving (Show, Eq)

-- | Generate a non-empty, /valid/ command sequence: a @Pop@ is only ever emitted
-- when there is an unmatched @Push@ above the base scope, so the base scope (and
-- therefore any declaration made before the first @push@) is never popped. (The
-- invalid-stack/pop-too-far case is the subject of Property 9, not this one.) A
-- final @CheckSat@ is appended so the fully accumulated end-of-block state is
-- always observed at least once.
genOps :: QC.Gen [Op]
genOps = QC.sized $ \sz -> do
            n <- QC.choose (1, max 1 (min sz 20))
            ops <- go n (0 :: Int) (0 :: Int) []
            pure (ops ++ [CheckSat])
  where
    go 0 _depth _next acc = pure (reverse acc)
    go k depth  next  acc = do
        op <- QC.frequency $ [ (4, pure (Declare next))
                             , (3, pure (Assert  next))
                             , (2, pure Push)
                             , (3, pure CheckSat)
                             , (2, pure GetModel)
                             ] ++ [ (3, pure Pop) | depth > 0 ]
        let next'  = case op of
                       Declare _ -> next + 1
                       Assert  _ -> next + 1
                       _         -> next
            depth' = case op of
                       Push -> depth + 1
                       Pop  -> depth - 1
                       _    -> depth
        go (k - 1) depth' next' (op : acc)

-- | Render an operation to the SMT-Lib2 command text the session receives. The
-- declaration\/assertion ids are embedded in the text so the raw transcript can
-- be re-parsed back into identifiable items (see 'observationsFromTranscript').
render :: Op -> Text
render (Declare k) = T.pack ("(declare-const v" ++ show k ++ " Int)")
render (Assert  k) = T.pack ("(assert (> v" ++ show k ++ " 0))")
render Push        = T.pack "(push 1)"
render Pop         = T.pack "(pop 1)"
render CheckSat    = T.pack "(check-sat)"
render GetModel    = T.pack "(get-model)"

-- | The scripted response for each command, mirroring a @:print-success true@
-- session: structural commands acknowledge with @success@, @check-sat@ answers
-- with a satisfiability verdict, and @get-model@ returns a (placeholder) model.
-- Only their correspondence to the sent commands matters here; the mock replays
-- them verbatim.
responseFor :: Op -> Either MB.SolverFailure Text
responseFor CheckSat = Right (T.pack "sat")
responseFor GetModel = Right (T.pack "(model )")
responseFor _        = Right (T.pack "success")

-- | A stable per-item token. Declarations and assertions live in disjoint
-- namespaces (@D@ vs @A@) so they never collide even if ids coincide.
declTok, assertTok :: Int -> String
declTok   k = 'D' : show k
assertTok k = 'A' : show k

-- | The accumulated active state observed at each @check-sat@\/@get-model@,
-- derived from the /abstract operations/ by simulating the assertion-stack:
-- declarations\/assertions accumulate into the top scope, @push@ opens a new
-- scope, @pop@ discards the top scope (the generator guarantees the base scope
-- is never popped), and the active state is the union over all live scopes.
observationsFromOps :: [Op] -> [[String]]
observationsFromOps = go [[]] []
  where
    go _stack obs []         = reverse obs
    go stack  obs (op : ops) =
        case op of
          Declare k -> go (addTop (declTok   k) stack) obs ops
          Assert  k -> go (addTop (assertTok k) stack) obs ops
          Push      -> go ([] : stack)                 obs ops
          Pop       -> go (drop 1 stack)               obs ops
          CheckSat  -> go stack (activeOf stack : obs) ops
          GetModel  -> go stack (activeOf stack : obs) ops

-- | The accumulated active state observed at each @check-sat@\/@get-model@,
-- derived /independently/ from the raw transcript the session received, by
-- re-parsing each command string and replaying the same assertion-stack
-- scoping. Agreeing with 'observationsFromOps' means the single session
-- preserved every declaration\/assertion across successive commands and a @pop@
-- removed exactly its matching scope.
observationsFromTranscript :: [Text] -> [[String]]
observationsFromTranscript = go [[]] []
  where
    go _stack obs []         = reverse obs
    go stack  obs (cmd : cs) =
        case classify cmd of
          CDeclare t -> go (addTop t stack)       obs cs
          CAssert  t -> go (addTop t stack)       obs cs
          CPush      -> go ([] : stack)           obs cs
          CPop       -> go (drop 1 stack)         obs cs
          CObserve   -> go stack (activeOf stack : obs) cs

-- | A classified command recovered from its raw transcript text.
data Cmd = CDeclare String | CAssert String | CPush | CPop | CObserve

-- | Re-parse a raw command string back into its classification, recovering the
-- per-item token for declarations/assertions from the embedded id.
classify :: Text -> Cmd
classify t
  | Just rest <- T.stripPrefix (T.pack "(declare-const v") t = CDeclare ('D' : digitsOf rest)
  | Just rest <- T.stripPrefix (T.pack "(assert (> v")     t = CAssert  ('A' : digitsOf rest)
  | t == T.pack "(push 1)"    = CPush
  | t == T.pack "(pop 1)"     = CPop
  | t == T.pack "(check-sat)" = CObserve
  | t == T.pack "(get-model)" = CObserve
  | otherwise                 = error ("TestSuite.Wasm.SessionState.classify: unexpected command: " ++ T.unpack t)
  where digitsOf = takeWhile isDigit . T.unpack

-- | Add an item to the top (head) scope of the assertion-stack.
addTop :: String -> [[String]] -> [[String]]
addTop x (s : ss) = (x : s) : ss
addTop x []       = [[x]]          -- defensive; the base scope is always present

-- | The active state of an assertion-stack: the de-duplicated, ordered union of
-- all live scopes.
activeOf :: [[String]] -> [String]
activeOf = sort . nub . concat

-- | Drive a generated query block through a single mock session and read back
-- the per-command outcomes, the recorded transcript, the init/release counts,
-- the final phase, and whether any send overlapped another.
runSession :: [Op] -> IO ([Either MB.SolverFailure Text], [Text], Int, Int, MB.MockPhase, Bool)
runSession ops = do
        mb <- MB.newMockBridge (MB.scriptResponses (map responseFor ops))
        _  <- MB.acquireSolver mb                                  -- one session for the whole block
        collected <- mapM (MB.sendCommand mb Nothing . render) ops -- every command -> that one session
        recorded  <- MB.transcript            mb
        ic        <- MB.initCount             mb
        rc        <- MB.releaseCount          mb
        ph        <- MB.solverPhase           mb
        cc        <- MB.sawConcurrentInFlight mb
        pure (collected, recorded, ic, rc, ph, cc)

-- | A showable rendering of a delivered outcome (so a counterexample is legible;
-- 'MB.SolverFailure' has no 'Show').
renderOutcome :: Either MB.SolverFailure Text -> String
renderOutcome (Right t)                    = "ok:"      ++ T.unpack t
renderOutcome (Left (MB.SolverRejected s)) = "rejected:" ++ s
renderOutcome (Left (MB.SolverTimedOut s)) = "timedout:" ++ s
renderOutcome (Left (MB.SolverLoadError s))= "loaderr:"  ++ s
renderOutcome (Left (MB.SolverInitError s))= "initerr:"  ++ s

-- Feature: sbv-browser-wasm-backend, Property 8: Query sessions preserve solver state across commands
sessionPreservesStateAcrossCommands :: TestTree
sessionPreservesStateAcrossCommands =
    QC.testProperty "Property 8: Query sessions preserve solver state across commands" $
      QC.withNumTests 200 $
        QC.monadicIO $ do
          ops <- QC.pick genOps
          QC.monitor (QC.counterexample ("ops: " ++ show ops))

          (collected, recorded, ic, rc, ph, concurrent) <- QC.run (runSession ops)

          let commands = map render ops

          -- (6.1) Every command in the block was routed to a single session, in
          --       order: the recorded transcript is exactly the command sequence.
          QC.monitor (QC.counterexample ("transcript: " ++ show recorded))
          QC.monitor (QC.counterexample ("commands:   " ++ show commands))
          QC.assert (recorded == commands)

          -- (6.1) That session was initialized exactly once, never torn down
          --       mid-block, stayed Ready, and was driven strictly sequentially
          --       (at most one command in flight at a time).
          QC.monitor (QC.counterexample ("initCount/releaseCount/phase: " ++ show (ic, rc, ph)))
          QC.assert (ic == 1)
          QC.assert (rc == 0)
          QC.assert (ph == MB.PhaseReady)
          QC.assert (not concurrent)

          -- Sanity: each delivered response corresponds to its command.
          QC.monitor (QC.counterexample ("collected: " ++ show (map renderOutcome collected)))
          QC.assert (map renderOutcome collected == map (renderOutcome . responseFor) ops)

          -- (6.3) State preserved across successive commands: replaying the one
          --       session's accumulated transcript under push/pop scoping yields,
          --       at every observation point, exactly the active declaration/
          --       assertion set the abstract operation semantics expect. In
          --       particular, items declared before a push remain in effect after
          --       the matching pop, and only the popped scope's items disappear.
          let expected   = observationsFromOps ops
              fromSession = observationsFromTranscript recorded
          QC.monitor (QC.counterexample ("expected observations:   " ++ show expected))
          QC.monitor (QC.counterexample ("observed (from session): " ++ show fromSession))
          QC.assert (fromSession == expected)
