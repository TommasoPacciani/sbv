# Requirements Document

## Introduction

This feature defines a browser-usable variant of the SBV library (version 14.2, BSD-3, GHC/Haskell)
whose primary purpose is to serve as the SMT backend for the Grisette library running inside a web
browser. Today, SBV solves problems by spawning an external SMT solver (for example, Z3) as an
operating-system child process and communicating with it over stdin/stdout pipes. Browsers have no
subprocess model, no filesystem in the OS sense, no process environment, and (under the GHC
WebAssembly/JS runtime) a single-threaded runtime. The official Microsoft Z3 WebAssembly build,
distributed as the `z3-solver` npm package, instead exposes an asynchronous (Promise/callback)
string-in/string-out interface.

The goal is a variant of SBV that drives an in-browser WASM SMT solver through a pluggable solver
engine instead of spawning a process, while preserving SBV's existing SMT-Lib2 generation and its
public solving API so Grisette (already running in the browser) can use it unchanged. Compiling
Grisette itself to WebAssembly is explicitly out of scope; this spec only concerns making SBV usable
as an in-browser backend.

### In Scope

- A pluggable solver engine that communicates with an in-browser WASM SMT solver (primary target:
  the `z3-solver` npm package) instead of an OS process.
- Bridging SBV's synchronous IO solving API to the WASM solver's asynchronous interface.
- Preserving the existing SMT-Lib2 text generation.
- Virtualizing or avoiding OS process, environment-variable, and filesystem access on the browser path.
- A build strategy that compiles the `libBF` C-library FFI dependency from its bundled portable C sources for the WASM target, so SBV's arbitrary-precision floating-point type and support remain available in the browser build.
- Defining the concurrency model on the single-threaded browser runtime.
- Keeping the existing native (process-based) behavior intact.

### Out of Scope

- Compiling Grisette to WebAssembly.
- C code generation (`Data.SBV.Compilers.CodeGen`, `Data.SBV.Tools.CodeGen`) in the browser.
- Supporting WASM solvers other than the primary Z3 target (others remain possible future work).
- Changing SBV's symbolic front end, SMT-Lib2 dialect, or model-parsing logic.

## Glossary

- **SBV**: The existing Symbolic Bit Vectors Haskell library (version 14.2) contained in this workspace.
- **SBV_Browser**: The browser-targeted variant/build of SBV defined by this spec.
- **Native_SBV**: The existing behavior of SBV on a conventional operating system, which spawns an external solver process.
- **Browser_Engine**: The alternative `SMTEngine` implementation (matching the existing `SMTEngine` type in `Data.SBV.Core.Symbolic`) that communicates with an in-browser WASM SMT solver instead of spawning an operating-system process.
- **WASM_Solver**: An SMT solver compiled to WebAssembly that runs inside the browser and exposes an asynchronous request/response interface.
- **Z3_WASM**: The specific WASM_Solver provided by the official Microsoft Z3 build distributed as the `z3-solver` npm package; the default WASM_Solver for SBV_Browser.
- **SMTLib2_Generator**: SBV's existing component (`Data.SBV.SMT.SMTLib2`) that renders symbolic problems into SMT-Lib2 command text.
- **Query_State**: SBV's `QueryState` record (`queryAsk`, `querySend`, `queryRetrieveResponse`, `queryTerminate`, `queryConfig`, `queryTimeOutValue`, `queryAssertionStackDepth`) used as the communication abstraction between SBV and a solver.
- **Async_Bridge**: The mechanism that adapts the WASM_Solver's asynchronous (Promise/callback) interface to the synchronous IO operations that SBV's engine and Query_State expect.
- **JSFFI**: The GHC WebAssembly backend's JavaScript Foreign Function Interface, including its support for awaiting JavaScript Promises.
- **Build_Configuration**: The cabal package configuration together with the CPP/flag machinery that selects the browser code path versus the native code path.
- **Browser_Path**: The set of code paths executed when SBV_Browser runs under the GHC WebAssembly runtime in a browser.
- **Grisette**: The client library, running in the browser, that uses SBV_Browser as its SMT backend.
- **Solving_API**: SBV's public solving entry points used by Grisette, namely `prove`, `sat`, `allSat`, `optimize`, `runSMTWith`, and query mode (`Data.SBV.Control`).
- **Query_Timeout**: The optional, per-interaction solver timeout a caller may set via SBV's `Data.SBV.Control.timeout` combinator (carried as `queryTimeOutValue :: Maybe Int`, in microseconds). It defaults to unset, in which case Native_SBV waits indefinitely for a solver response. When set, Native_SBV bounds its own wait and also emits `(set-option :timeout N)` so the solver itself returns `unknown` once the limit is exceeded.
- **Solver_Failure**: A condition in which the WASM_Solver cannot deliver a valid response to a sent command — for example, the underlying asynchronous call (Promise) is rejected, the solver crashes, or the connection to the solver is lost. This is the Browser_Path analog of Native_SBV detecting that the solver process died (`hGetLine: end of file`).
- **Comm_Watchdog**: Native_SBV's internal pipe-recovery timeouts (`setCommandTimeOut` = 2s, `defaultLineTimeOut` = 5s, scaled by `SBV_COMM_TIMEOUT_FACTOR`) that guard the line-by-line reading of a solver's stdout pipe and trigger stderr recovery when successive lines stall. These guard the OS pipe/handle model and do not apply to the WASM single-message interface, where each command yields exactly one complete response or a Solver_Failure.
- **Build_Agent**: Any automated build-and-test or verification agent that issues build or test commands for SBV or SBV_Browser during implementation and verification of this feature.
- **Standard_Build_Command**: The project's standard, unmodified cabal build invocation as configured by the project's existing cabal files — specifically `cabal build` for a native operating-system target and `wasm32-wasi-cabal build` for the WebAssembly target — carrying no command-line flags beyond those the project's cabal configuration already specifies.
- **Injected_Build_Flag**: Any compiler optimization flag or alternative build option supplied on the build command line that is not part of the project's existing cabal configuration — for example `-O1`, `-O2`, `-optc-O1`, a `--ghc-options` flag, or an ad-hoc optimization level — and that would alter build behavior relative to the Standard_Build_Command.

## Requirements

### Requirement 1: Pluggable Browser SMT Engine

**User Story:** As a Grisette developer running in the browser, I want SBV to drive an in-browser WASM SMT solver through a pluggable engine, so that I can solve SMT problems without spawning an operating-system process.

#### Acceptance Criteria

1. THE SBV_Browser SHALL provide a Browser_Engine value that conforms to the existing `SMTEngine` type signature defined in `Data.SBV.Core.Symbolic`.
2. WHEN a solver configuration selects the Browser_Engine, THE SBV_Browser SHALL route solver communication through the Browser_Engine instead of `standardEngine`.
3. WHEN the `queryAsk`, `querySend`, and `queryRetrieveResponse` communication fields are configured, THE Browser_Engine SHALL construct a Query_State whose `queryAsk`, `querySend`, and `queryRetrieveResponse` fields send commands to and receive responses from the WASM_Solver rather than an operating-system process.
4. IF the `queryAsk`, `querySend`, and `queryRetrieveResponse` communication fields are not configured, THEN THE Browser_Engine SHALL NOT send any command to the WASM_Solver and SHALL report a configuration error to the caller.
4. WHEN a caller invokes a Solving_API entry point with a Browser_Engine configuration, THE SBV_Browser SHALL execute the request through the Browser_Engine.
5. IF a Solver_Failure occurs while a Solving_API or query operation is active, THEN THE Browser_Engine SHALL abort that operation, report an error to the caller that identifies the Solver_Failure, and SHALL NOT return a solver result for that operation.
6. WHERE a Query_Timeout is set for an interaction, THE Browser_Engine SHALL bound its wait for that interaction's response by the Query_Timeout; WHERE no Query_Timeout is set, THE Browser_Engine SHALL wait indefinitely for the response, matching Native_SBV.

### Requirement 2: In-Browser Communication Without Process Spawning or Handle I/O

**User Story:** As a developer targeting the browser, I want SBV to talk to the solver using string messages rather than OS pipes and processes, so that solving works where no subprocess or file handle exists.

#### Acceptance Criteria

1. WHEN the Browser_Engine executes a solver task, THE SBV_Browser SHALL communicate with the WASM_Solver without invoking `runInteractiveProcess` or any other operating-system process-spawning function.
2. THE Browser_Engine SHALL transmit each SMT-Lib2 command to the WASM_Solver as a single complete string message and SHALL receive each solver response as a single complete string message, without sharing an operating-system byte stream, pipe, or file handle between command and response.
3. WHEN running on the Browser_Path, THE Browser_Engine SHALL send commands and receive responses without using any operating-system handle I/O function (`hGetLine`, `hReady`, `hGetChar`, `hFlush`, `hClose`, or `hGetContents`).
4. WHEN a command expects a response, THE Browser_Engine SHALL accumulate WASM_Solver output until it forms a complete s-expression AND its parentheses are balanced, treating both as separate conditions that must hold, and SHALL return that complete s-expression to SBV before SBV sends the next command.
5. IF a command, after its leading whitespace is removed, is empty or begins with the comment marker `;`, THEN THE Browser_Engine SHALL return the synthetic `success` response that SBV expects without forwarding that command to the WASM_Solver.
6. IF a command expects a response but a Solver_Failure occurs before a complete, balanced s-expression is received, THEN THE Browser_Engine SHALL raise an `SBVException` carrying the sent command and any partial response received, and SHALL NOT return a response for that command to SBV.

### Requirement 3: Asynchronous-to-Synchronous Bridging

**User Story:** As a developer, I want SBV's synchronous solving calls to work against the asynchronous WASM solver, so that the existing API behaves correctly in the browser.

#### Acceptance Criteria

1. WHEN the Browser_Engine sends a command to the WASM_Solver, THE Async_Bridge SHALL await the WASM_Solver's asynchronous response and, upon receipt of a complete response, present that response to SBV as a synchronous IO `String`.
2. WHILE awaiting a WASM_Solver response, THE Async_Bridge SHALL yield control to the browser event loop without blocking the single-threaded browser runtime, so that the WASM_Solver's pending asynchronous work executes and produces the response.
3. THE Async_Bridge SHALL deliver WASM_Solver responses to SBV in the same order in which their commands were sent, SHALL clear its awaiting state immediately upon delivering a response, and SHALL NOT begin awaiting a subsequent command's response until the response to the most recently sent command has been delivered, so that each delivered response corresponds to its originating command.
4. IF the WASM_Solver reports an error or its asynchronous response is rejected while processing a request (a Solver_Failure), THEN THE Async_Bridge SHALL surface the failure to SBV as an `SBVException` that identifies the sent command and the failure cause, and SHALL NOT return a synchronous string result for that request.
5. WHERE a Query_Timeout is set for the interaction, IF the WASM_Solver's asynchronous response does not complete within the Query_Timeout, THEN THE Async_Bridge SHALL surface a timeout error to SBV as an `SBVException` and SHALL NOT return a synchronous string result for that request.

### Requirement 4: Preserve SMT-Lib2 Generation

**User Story:** As a maintainer, I want the browser variant to reuse SBV's existing SMT-Lib2 generation, so that solver behavior matches the native variant and no second dialect is introduced.

#### Acceptance Criteria

1. THE SBV_Browser SHALL generate SMT-Lib2 command text exclusively via the existing SMTLib2_Generator, applying no insertion, deletion, reordering, or character-level modification to the generator's output.
2. WHEN solving a given symbolic problem under a given solver configuration, THE Browser_Engine SHALL transmit to the WASM_Solver an SMT-Lib2 command sequence that is byte-for-byte identical, and in the same command order, to the SMT-Lib2 command sequence Native_SBV transmits to an external solver for that same problem and configuration, excluding operating-system command-line invocation options, and SHALL NOT add solver-specific optimizations, debugging annotations, or any other modification to that command sequence.
3. WHEN the WASM_Solver returns a response, THE SBV_Browser SHALL parse that response using SBV's existing response-parsing logic and SHALL NOT introduce an alternative response parser.
4. WHEN extracting a model from a satisfiable WASM_Solver result, THE SBV_Browser SHALL produce model values using SBV's existing model-extraction logic and SHALL NOT introduce an alternative model-extraction implementation.

### Requirement 5: Z3 WASM Solver Configuration

**User Story:** As a Grisette developer, I want a ready-to-use Z3 WASM configuration, so that I can solve problems with the official browser Z3 build without manual wiring.

#### Acceptance Criteria

1. THE SBV_Browser SHALL provide a solver configuration that targets Z3_WASM as the default WASM_Solver.
2. THE Z3_WASM configuration SHALL omit the operating-system command-line options (`-nw`, `-in`, `-smt2`) and SHALL pass no operating-system process command-line arguments to the WASM_Solver.
3. WHERE the WASM_Solver requires module loading or initialization before use, THE SBV_Browser SHALL initialize the WASM_Solver exactly once before sending the first SMT-Lib2 command and SHALL NOT re-initialize it within the same session.
4. WHILE WASM_Solver initialization is in progress, THE SBV_Browser SHALL queue solver operations and execute them, in the order received, only after initialization completes.
5. IF WASM_Solver initialization fails while solver operations are queued, THEN THE SBV_Browser SHALL fail each queued operation with a descriptive error and SHALL NOT leave any queued operation blocked indefinitely.
6. THE Z3_WASM configuration SHALL advertise the same solver capabilities that Native_SBV advertises for Z3, including `supportsIEEE754`, because arbitrary-precision and IEEE floating-point support is retained on the Browser_Path per Requirement 10.

### Requirement 6: Query Mode and Incremental Solving

**User Story:** As a Grisette developer, I want incremental query-mode solving to work in the browser, so that Grisette can issue multiple assertions, push/pop, and re-check across one solver session.

#### Acceptance Criteria

1. WHEN a caller runs a query block (`runSMTWith` with `query`) on the Browser_Path, THE Browser_Engine SHALL route every command in that block to a single WASM_Solver session.
2. WHEN SBV issues the `(set-option :print-success true)` coordination command, THE Browser_Engine SHALL deliver the WASM_Solver's `success` response so that SBV's command coordination operates correctly.
3. WHILE a query session is active, THE Browser_Engine SHALL preserve WASM_Solver state across successive commands such that declarations and assertions remain in effect until a matching `pop` removes them, so that `push`, `pop`, `check-sat`, and `get-model` observe the accumulated session state.
4. IF a `push`, `pop`, `check-sat`, or `get-model` command is issued while no query session is active, THEN THE SBV_Browser SHALL reject the command with an error indicating no active session, SHALL NOT forward the command to a WASM_Solver, and SHALL leave the no-active-session state unchanged.
5. IF a `pop` command requests removal of more assertion levels than the number of unmatched `push` commands in the active session, THEN THE SBV_Browser SHALL reject the command with an invalid-stack-operation error and SHALL preserve the current session state.
6. WHEN a query session ends, THE Browser_Engine SHALL terminate the WASM_Solver session through the Query_State `queryTerminate` callback, after which the terminated session SHALL NOT accept further commands.

### Requirement 7: Environment and Executable Discovery Virtualization

**User Story:** As a developer, I want SBV to determine its configuration without OS environment variables or executable lookup, so that it works where no PATH or process environment exists.

#### Acceptance Criteria

1. WHEN running on the Browser_Path, THE SBV_Browser SHALL determine the active solver from the supplied solver configuration without calling `findExecutable` and without consulting an operating-system PATH.
2. WHEN running on the Browser_Path, THE SBV_Browser SHALL determine solver options from the supplied solver configuration without requiring the `SBV_Z3` or `SBV_Z3_OPTIONS` environment variables.
3. WHEN running on the Browser_Path, THE SBV_Browser SHALL NOT require the `SBV_COMM_TIMEOUT_FACTOR` environment variable, AND SHALL NOT depend on the Comm_Watchdog, since the WASM single-message interface delivers each response as one complete message rather than line-by-line.
4. WHERE a setting that Native_SBV sources from an environment variable is needed on the Browser_Path, THE SBV_Browser SHALL source that setting from the supplied solver configuration instead.
5. IF no solver is explicitly selected on the Browser_Path, THEN THE SBV_Browser SHALL fall back to Z3_WASM as the default solver.

### Requirement 8: Process Lifecycle Without an Operating-System Process

**User Story:** As a maintainer, I want solver task completion and cleanup to work without an OS process, so that the browser path does not depend on process exit codes or process termination calls.

#### Acceptance Criteria

1. WHEN a browser solver task completes, THE Browser_Engine SHALL finalize the WASM_Solver session by releasing the WASM_Solver resources held by that session, without calling `waitForProcess` or `terminateProcess`.
2. WHEN finalizing a browser solver task, THE Browser_Engine SHALL treat retrieval of a complete solver response to the task's final command as task success, independently of any operating-system `ExitCode`.
3. IF a browser solver task is aborted by a forwarded exception, THEN THE Browser_Engine SHALL release the WASM_Solver resources held by that session before propagating the exception to the caller.
4. WHEN the Browser_Engine has released WASM_Solver resources for a task aborted by a forwarded exception, THE Browser_Engine SHALL re-raise that original forwarded exception to the caller without substituting a different exception.
5. IF releasing WASM_Solver resources fails while aborting a browser solver task, THEN THE Browser_Engine SHALL re-raise the original forwarded exception rather than the resource-release error.

### Requirement 9: Concurrency Under a Single-Threaded Runtime

**User Story:** As a developer, I want single-solver operations to work on the single-threaded browser runtime, so that core solving does not depend on OS threads.

#### Acceptance Criteria

1. WHERE the Browser_Path runs under a single-threaded runtime, THE SBV_Browser SHALL complete single-solver `prove`, `sat`, `allSat`, and `optimize` operations and return their results using a single thread of execution, without spawning or requiring operating-system threads.
2. WHEN the Browser_Engine collects a WASM_Solver response, THE Browser_Engine SHALL assemble the complete response for each command without using `forkIO`- or `MVar`-based stdout/stderr draining.
3. WHERE a browser-compatible concurrency mechanism is available on the Browser_Path, WHEN a caller invokes a concurrent-solver combinator (`proveWithAny`, `proveWithAll`, `satWithAny`, `satWithAll`), THE SBV_Browser SHALL execute the combinator through that mechanism and return the combinator's result.
4. IF a caller invokes a concurrent-solver combinator (`proveWithAny`, `proveWithAll`, `satWithAny`, `satWithAll`) on the Browser_Path and no browser-compatible concurrency mechanism is available, THEN THE SBV_Browser SHALL reject the call with an unsupported-operation error that identifies the invoked combinator and SHALL NOT leave any WASM_Solver session active, including any session created by a previous successful operation.
5. IF the SBV_Browser rejects a concurrent-solver combinator as an unsupported operation, THEN THE SBV_Browser SHALL return that error synchronously to the caller without awaiting an operating-system thread or background task that the single-threaded runtime cannot schedule.

### Requirement 10: libBF C-Source Compilation for the WebAssembly Target

**User Story:** As a maintainer building for WebAssembly, I want the `libBF` C-library dependency compiled from its bundled portable C sources for the WASM target, so that SBV's arbitrary-precision floating-point type and the IEEE/arbitrary-precision floating-point theories remain present in the browser build and Grisette compiles against the browser SBV.

#### Acceptance Criteria

1. WHERE the build target is WebAssembly, THE Build_Configuration SHALL include the `libBF` dependency and compile its bundled portable C sources for that target, producing a loadable WebAssembly artifact that retains arbitrary-precision floating-point support.
2. WHERE the build target is WebAssembly, THE Build_Configuration SHALL retain the arbitrary-precision floating-point type and code paths (`Data.SBV.Core.SizedFloats`, including SBV's `FloatingPoint`/`FP` type, and the `libBF`-dependent paths in `Data.SBV.Core.Operations` and `Data.SBV.Core.Floating`) in the browser build, so that SBV's `FloatingPoint`/`FP` type remains present and Grisette compiles against the browser SBV.
3. WHERE the build target is WebAssembly, THE SBV_Browser SHALL keep the boolean, bit-vector, unbounded-integer, real, and IEEE/arbitrary-precision floating-point theories required by Grisette fully operational on the Browser_Path.
4. WHEN a caller invokes an arbitrary-precision floating-point operation on the Browser_Path, THE SBV_Browser SHALL execute that operation through the compiled `libBF` C sources, producing the same result that Native_SBV produces for the same operation.
5. WHERE the build target is not WebAssembly, THE Build_Configuration SHALL include the `libBF` dependency and the arbitrary-precision floating-point code paths exactly as Native_SBV does, leaving native floating-point behavior identical.
6. IF the bundled `libBF` C sources fail to compile or link for the WebAssembly target, THEN THE Build_Configuration SHALL fail the build with detailed error information identifying the compile or link failure rather than silently producing an artifact, requiring manual correction of the build configuration.

### Requirement 11: Filesystem Access Virtualization

**User Story:** As a developer, I want solving in the browser to avoid OS filesystem access, so that the solving path works where no OS filesystem exists.

#### Acceptance Criteria

1. WHEN running a Solving_API entry point on the Browser_Path, THE SBV_Browser SHALL complete the operation without reading from or writing to an operating-system filesystem.
2. WHERE transcript recording is requested on the Browser_Path, THE SBV_Browser SHALL direct all transcript output — transcript start, per-message records, and finalization — to a browser-available sink that retains the same transcript content, without performing an operating-system file write (such as `writeFile` or `appendFile`).
3. WHEN the `safe`/`safeWith` path runs on the Browser_Path, THE SBV_Browser SHALL produce its SafeResult list without calling `getCurrentDirectory`, reporting each source-location file path unmodified rather than relativized to a current working directory.
4. IF a Solving_API code path on the Browser_Path attempts an operating-system filesystem operation that cannot be virtualized, THEN THE SBV_Browser SHALL prevent the operating-system filesystem access from occurring and SHALL report an explicit error identifying the unsupported filesystem operation, without reading from or writing to an operating-system filesystem.

### Requirement 12: Dual-Target Build Configuration

**User Story:** As a maintainer, I want both the native and browser builds to be supported from one source tree, so that adding the browser variant does not break existing native users.

#### Acceptance Criteria

1. THE Build_Configuration SHALL build SBV for a native operating-system target to completion without build errors, producing a usable artifact that uses the existing process-based engine.
2. THE Build_Configuration SHALL build SBV_Browser for the GHC WebAssembly target to completion without build errors, producing a usable artifact.
3. WHEN building for the browser target, THE Build_Configuration SHALL exclude or replace every module and code path that depends on `System.Process`, `System.Directory`, and `System.Environment` along the Solving_API path, such that the resulting artifact retains no compile-time dependency on those three modules along the Solving_API path.
4. IF a module or code path that depends on `System.Process`, `System.Directory`, or `System.Environment` along the Solving_API path is neither excluded nor replaced while building for the browser target, THEN THE Build_Configuration SHALL report detailed error information identifying the specific problematic modules and then fail the build, and SHALL NOT produce a partial-exclusion artifact.
5. WHEN building for the native target, THE SBV_Browser changes SHALL leave the native solving behavior identical to the existing process-based behavior that preceded the SBV_Browser changes.
6. WHEN building for the native target, THE Build_Configuration SHALL allow native builds to use `System.Process`, `System.Directory`, and `System.Environment` without any added exclusion or replacement.

### Requirement 13: Error Handling on the Browser Path

**User Story:** As a developer, I want clear errors when the browser solver fails, so that I can diagnose problems without an OS process to inspect.

#### Acceptance Criteria

1. IF the WASM_Solver fails to load, THEN THE SBV_Browser SHALL raise an error to the caller that identifies the WASM_Solver and indicates that the failure occurred during the loading phase, and SHALL NOT return a solving result for the requested operation.
2. IF the WASM_Solver loads successfully but fails to initialize, THEN THE SBV_Browser SHALL raise an error to the caller that identifies the WASM_Solver, indicates that the failure occurred during the initialization phase, is distinguishable from a loading-phase failure, and SHALL NOT return a solving result for the requested operation.
3. IF the WASM_Solver returns a non-success response, or a response that cannot be parsed, to a command that expected a `success` response, THEN THE SBV_Browser SHALL raise an `SBVException` that carries the sent command text and the received response text, and SHALL NOT return a normal result for that command.
4. IF a Solver_Failure occurs while awaiting a response, THEN THE SBV_Browser SHALL raise an `SBVException` to the caller that identifies the command in flight and the failure cause, and SHALL release the WASM_Solver resources associated with that request.
5. WHERE a Query_Timeout is set for an interaction, IF the WASM_Solver does not produce a complete response within the Query_Timeout, THEN THE SBV_Browser SHALL raise a timeout error to the caller that identifies the command that timed out; WHERE no Query_Timeout is set, THE SBV_Browser SHALL wait indefinitely for the response (matching Native_SBV) rather than imposing an internal default timeout.
6. WHILE awaiting a WASM_Solver response on the Browser_Path, THE SBV_Browser SHALL enforce any applicable Query_Timeout through a mechanism that operates on the single-threaded browser runtime and does not depend on `System.Timeout` preempting a blocked thread.

### Requirement 14: Grisette Backend Compatibility

**User Story:** As a Grisette developer, I want SBV_Browser to behave like native SBV for the operations Grisette uses, so that Grisette runs in the browser without changing how it calls SBV.

#### Acceptance Criteria

1. THE SBV_Browser SHALL expose on the Browser_Path the Solving_API entry points `prove`, `sat`, `allSat`, `optimize`, `runSMTWith`, and query mode, presenting the same call signatures and type interfaces that Native_SBV exposes for those entry points.
2. WHEN Grisette submits a symbolic problem through SBV_Browser, THE SBV_Browser SHALL return exactly one classification from the set {satisfiable, unsatisfiable, unknown} that is identical to the classification Native_SBV returns for the same problem when both use the same Z3 version and the same solver configuration.
3. WHEN SBV_Browser returns a satisfiable result for a submitted problem, THE SBV_Browser model SHALL evaluate every submitted constraint to true, and MAY assign variable values that differ from those Native_SBV assigns for the same problem.
4. WHEN Grisette extracts a model from a satisfiable result on the Browser_Path, THE SBV_Browser SHALL produce parsed model values using SBV's existing model-extraction logic, presenting them in the same value representation that Native_SBV produces for the same model.

### Requirement 15: Standard, Unmodified Build Invocation During Implementation and Verification

**User Story:** As a maintainer, I want build and test agents to use only the project's standard cabal build invocation, so that build behavior stays reproducible and is not silently altered by injected optimization or compiler flags.

#### Acceptance Criteria

1. WHEN a Build_Agent builds SBV for a native operating-system target during implementation or verification, THE Build_Agent SHALL invoke the Standard_Build_Command `cabal build` and SHALL pass no Injected_Build_Flag on the command line.
2. WHEN a Build_Agent builds SBV_Browser for the WebAssembly target during implementation or verification, THE Build_Agent SHALL invoke the Standard_Build_Command `wasm32-wasi-cabal build` and SHALL pass no Injected_Build_Flag on the command line.
3. IF a build or test step would require any flag or option beyond the Standard_Build_Command, THEN THE Build_Agent SHALL record the standard configuration in the project's cabal files instead of supplying an Injected_Build_Flag on the command line, so that the standard invocation reproduces the intended build behavior.
4. WHERE solver options, compiler optimization levels, or other build settings are needed, THE Build_Agent SHALL source those settings from the project's existing cabal configuration rather than from command-line build flags.
5. IF a Build_Agent issues a build command that includes an Injected_Build_Flag (for example `-O1`, `-O2`, `-optc-O1`, `--ghc-options`, or an ad-hoc optimization level), THEN that command SHALL be treated as a violation of this requirement, and THE Build_Agent SHALL re-issue the build using the Standard_Build_Command before relying on its result.
6. WHEN a Build_Agent reports a build or test result during verification, THE Build_Agent SHALL have produced that result from the Standard_Build_Command, so that the reported build behavior is reproducible from the project's standard, unmodified invocation.
