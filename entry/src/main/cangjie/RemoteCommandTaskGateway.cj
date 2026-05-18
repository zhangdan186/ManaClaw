package ohos_app_cangjie_entry

import std.collection.*
import std.convert.*

public class RemoteCommandTaskGateway <: RemoteTaskGateway {
    private let host: String
    private let port: Int32
    private let username: String
    private let password: String
    private let ssh: SshClient
    private let builder: CommandBuilder

    public init(host: String, port: Int32, username: String, password: String) {
        this.host = host
        this.port = port
        this.username = username
        this.password = password
        this.ssh = SshClient()
        this.builder = CommandBuilder()
    }

    public func initRemote(server: ServerConfig): Result<InitResult> {
        let _ = server
        let result = exec(builder.buildInitCommand(), 30000)
        if (!result.isOk) {
            return taskFail<InitResult>(result.error ?? "initRemote failed")
        }
        return taskOk<InitResult>(InitResult((result.value ?? "").trimAscii()))
    }

    public func createTask(task: Task, wrappedPrompt: String): Result<Unit> {
        let input = TaskCommandInput(
            task.id,
            task.title,
            task.repoPath,
            task.worktreePath,
            task.branchName,
            task.tmuxSession,
            ShellEscape.base64Encode(wrappedPrompt),
            task.mode
        )
        return unitFromExec(exec(builder.buildCreateTaskCommand(input), 120000))
    }

    public func startTask(task: Task): Result<Unit> {
        let input = TaskCommandInput(
            task.id,
            task.title,
            task.repoPath,
            task.worktreePath,
            task.branchName,
            task.tmuxSession,
            "",
            task.mode
        )
        return unitFromExec(exec(builder.buildStartTaskCommand(input), 120000))
    }

    public func listTasks(server: ServerConfig): Result<ArrayList<RemoteTaskRow>> {
        let _ = server
        let result = exec(builder.buildListTasksCommand(), 30000)
        if (!result.isOk) {
            return taskFail<ArrayList<RemoteTaskRow>>(result.error ?? "listTasks failed")
        }

        let rows = ArrayList<RemoteTaskRow>()
        for (rawLine in (result.value ?? "").split("\n")) {
            let line = rawLine.trimAscii()
            if (line.size == 0) {
                continue
            }
            match (parseTaskRow(line)) {
                case Some(row) => rows.append(row)
                case None => return taskFail<ArrayList<RemoteTaskRow>>("Malformed LIST row: ${line}")
            }
        }
        return taskOk<ArrayList<RemoteTaskRow>>(rows)
    }

    public func getTaskStatus(taskId: String): Result<RemoteTaskStatus> {
        let result = exec(builder.buildTaskStatusCommand(taskId), 30000)
        if (!result.isOk) {
            return taskFail<RemoteTaskStatus>(result.error ?? "getTaskStatus failed")
        }
        return parseTaskStatus(taskId, result.value ?? "")
    }

    public func tailLog(taskId: String, lines: Int64): Result<String> {
        return exec(builder.buildTailLogCommand(taskId, lines), 30000)
    }

    public func tailStderr(taskId: String): Result<String> {
        return exec(builder.buildTailStderrCommand(taskId), 30000)
    }

    public func stopTask(taskId: String): Result<Unit> {
        return unitFromExec(exec(builder.buildStopTaskCommand(taskId), 30000))
    }

    public func deleteTask(taskId: String): Result<Unit> {
        return unitFromExec(exec(builder.buildDeleteTaskCommand(taskId), 30000))
    }

    public func gitSummary(taskId: String): Result<String> {
        return exec(builder.buildGitSummaryCommand(taskId), 30000)
    }

    private func exec(command: String, timeoutMs: Int32): Result<String> {
        let res = ssh.execCommand(host, port, username, password, command, timeoutMs)
        if (res.code == 0) {
            return taskOk<String>(res.stdout)
        }

        let stderrText = if (res.stderr.size > 0) {
            res.stderr
        } else {
            "<empty>"
        }
        let stdoutText = if (res.stdout.size > 0) {
            res.stdout
        } else {
            "<empty>"
        }
        return taskFail<String>("remote exit=${res.code}\nSTDOUT:\n${stdoutText}\nSTDERR:\n${stderrText}")
    }

    private func unitFromExec(result: Result<String>): Result<Unit> {
        if (!result.isOk) {
            return taskFail<Unit>(result.error ?? "remote command failed")
        }
        return taskOk<Unit>(())
    }

    private func parseTaskRow(line: String): Option<RemoteTaskRow> {
        let parts = line.split("\t")
        if (parts.size < 7) {
            return None
        }
        let title = if (parts.size >= 8) {
            parts[7].trimAscii()
        } else {
            ""
        }
        return Some(RemoteTaskRow(
            parts[0].trimAscii(),
            title,
            taskStatusFromWire(parts[1].trimAscii()),
            parseRemoteBool(parts[2]),
            parseExitCode(parts[3]),
            parts[4].trimAscii(),
            parts[5].trimAscii(),
            parts[6].trimAscii()
        ))
    }

    private func parseTaskStatus(taskId: String, text: String): Result<RemoteTaskStatus> {
        let fields = HashMap<String, String>()
        for (rawLine in text.split("\n")) {
            let line = rawLine.trimAscii()
            if (line.size == 0) {
                continue
            }
            match (line.indexOf("=")) {
                case Some(index) =>
                    if (index > 0 && index + 1 <= line.size) {
                        fields[line[0..index].trimAscii()] = line[(index + 1)..].trimAscii()
                    }
                case None => ()
            }
        }

        if (!fields.contains("status") || !fields.contains("repo")) {
            return taskFail<RemoteTaskStatus>("Malformed STATUS output:\n${text}")
        }

        return taskOk<RemoteTaskStatus>(RemoteTaskStatus(
            fields.get("task_id") ?? taskId,
            fields.get("title") ?? "",
            taskStatusFromWire(fields.get("status") ?? "unknown"),
            parseRemoteBool(fields.get("live") ?? "false"),
            parseExitCode(fields.get("exit_code") ?? ""),
            fields.get("repo") ?? "",
            fields.get("worktree") ?? "",
            fields.get("branch") ?? "",
            fields.get("tmux") ?? deriveTmuxSession(taskId)
        ))
    }

    private func parseRemoteBool(value: String): Bool {
        return value.trimAscii() == "true"
    }

    private func parseExitCode(value: String): Option<Int64> {
        let text = value.trimAscii()
        if (text.size == 0) {
            return None
        }
        return Int64.tryParse(text)
    }
}
