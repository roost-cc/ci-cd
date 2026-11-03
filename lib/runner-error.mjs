export class RunnerError extends Error {
  constructor(message, exitCode = 1) {
    super(message);
    this.exitCode = exitCode;
  }
}

export function fail(message, exitCode = 1) {
  throw new RunnerError(message, exitCode);
}
