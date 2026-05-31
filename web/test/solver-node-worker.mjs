import { workerData } from 'node:worker_threads';
import { runSolver } from '../src/solver-worker.js';
await runSolver(workerData);
