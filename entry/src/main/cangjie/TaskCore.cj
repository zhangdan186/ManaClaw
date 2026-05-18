package ohos_app_cangjie_entry

import encoding.json.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.random.*
import std.time.*

public enum TaskStatus {
    | local_created
    | remote_created
    | worktree_created
    | running
    | completed
    | failed
    | stopped
    | unknown
    | deleted
}

public class Result<T> {
    public let isOk: Bool
    public let value: Option<T>
    public let error: Option<String>

    public init(isOk: Bool, value: Option<T>, error: Option<String>) {
        this.isOk = isOk
        this.value = value
        this.error = error
    }
}

public func taskOk<T>(value: T): Result<T> {
    return Result<T>(true, Some(value), None)
}

public func taskFail<T>(message: String): Result<T> {
    return Result<T>(false, None, Some(message))
}

public class Task {
    public var id: String
    public var title: String
    public var prompt: String
    public var serverId: String
    public var repoPath: String
    public var branchName: String
    public var worktreePath: String
    public var tmuxSession: String
    public var remoteTaskDir: String
    public var status: TaskStatus
    public var mode: RunMode
    public var createdAt: Int64
    public var updatedAt: Int64
    public var lastLogOffset: Int64
    public var lastError: Option<String>

    public init(
        id: String,
        title: String,
        prompt: String,
        serverId: String,
        repoPath: String,
        branchName: String,
        worktreePath: String,
        tmuxSession: String,
        remoteTaskDir: String,
        status: TaskStatus,
        mode: RunMode,
        createdAt: Int64,
        updatedAt: Int64,
        lastLogOffset: Int64,
        lastError: Option<String>
    ) {
        this.id = id
        this.title = title
        this.prompt = prompt
        this.serverId = serverId
        this.repoPath = repoPath
        this.branchName = branchName
        this.worktreePath = worktreePath
        this.tmuxSession = tmuxSession
        this.remoteTaskDir = remoteTaskDir
        this.status = status
        this.mode = mode
        this.createdAt = createdAt
        this.updatedAt = updatedAt
        this.lastLogOffset = lastLogOffset
        this.lastError = lastError
    }
}

public class ServerConfig {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int64
    public var username: String
    public var passwordRef: String
    public var defaultRepoPath: String
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(
        id: String,
        name: String,
        host: String,
        port: Int64,
        username: String,
        passwordRef: String,
        defaultRepoPath: String,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        this.id = id
        this.name = name
        this.host = host
        this.port = port
        this.username = username
        this.passwordRef = passwordRef
        this.defaultRepoPath = defaultRepoPath
        this.createdAt = createdAt
        this.updatedAt = updatedAt
    }
}

public class InitResult {
    public let message: String

    public init(message: String) {
        this.message = message
    }
}

public class RemoteTaskRow {
    public let taskId: String
    public let title: String
    public let status: TaskStatus
    public let live: Bool
    public let exitCode: Option<Int64>
    public let repo: String
    public let branch: String
    public let worktree: String

    public init(
        taskId: String,
        title: String,
        status: TaskStatus,
        live: Bool,
        exitCode: Option<Int64>,
        repo: String,
        branch: String,
        worktree: String
    ) {
        this.taskId = taskId
        this.title = title
        this.status = status
        this.live = live
        this.exitCode = exitCode
        this.repo = repo
        this.branch = branch
        this.worktree = worktree
    }
}

public class RemoteTaskStatus {
    public let taskId: String
    public let title: String
    public let status: TaskStatus
    public let live: Bool
    public let exitCode: Option<Int64>
    public let repo: String
    public let worktree: String
    public let branch: String
    public let tmux: String

    public init(
        taskId: String,
        title: String,
        status: TaskStatus,
        live: Bool,
        exitCode: Option<Int64>,
        repo: String,
        worktree: String,
        branch: String,
        tmux: String
    ) {
        this.taskId = taskId
        this.title = title
        this.status = status
        this.live = live
        this.exitCode = exitCode
        this.repo = repo
        this.worktree = worktree
        this.branch = branch
        this.tmux = tmux
    }
}

public class TaskDetail {
    public let task: Task
    public let log: String
    public let stderr: String
    public let live: Bool
    public let exitCode: Option<Int64>

    public init(task: Task, log: String, stderr: String, live: Bool, exitCode: Option<Int64>) {
        this.task = task
        this.log = log
        this.stderr = stderr
        this.live = live
        this.exitCode = exitCode
    }
}

public interface RemoteTaskGateway {
    func initRemote(server: ServerConfig): Result<InitResult>
    func createTask(task: Task, wrappedPrompt: String): Result<Unit>
    func startTask(task: Task): Result<Unit>
    func listTasks(server: ServerConfig): Result<ArrayList<RemoteTaskRow>>
    func getTaskStatus(taskId: String): Result<RemoteTaskStatus>
    func tailLog(taskId: String, lines: Int64): Result<String>
    func tailStderr(taskId: String): Result<String>
    func stopTask(taskId: String): Result<Unit>
    func deleteTask(taskId: String): Result<Unit>
    func gitSummary(taskId: String): Result<String>
}

private let TASK_STORE_PROCESS_CACHE = HashMap<String, ArrayList<Task>>()

public class TaskStore {
    private let storageDir: Path
    private let tasksFile: Path
    private let tasksBackupFile: Path
    private let storageKey: String
    private var memoryTasks: Option<ArrayList<Task>> = None

    public init() {
        let base = taskCoreStoragePath(".cc-mobile-local")
        this.storageDir = base
        this.tasksFile = base.join("tasks.json")
        this.tasksBackupFile = base.join("tasks.json.bak")
        this.storageKey = base.toString()
        ensureDirectory(base)
    }

    public init(storageDir: String) {
        let base = taskCoreStoragePath(storageDir)
        this.storageDir = base
        this.tasksFile = base.join("tasks.json")
        this.tasksBackupFile = base.join("tasks.json.bak")
        this.storageKey = base.toString()
        ensureDirectory(base)
    }

    public func loadTasks(): ArrayList<Task> {
        match (TASK_STORE_PROCESS_CACHE.get(storageKey)) {
            case Some(tasks) =>
                memoryTasks = Some(cloneTasks(tasks))
                return cloneTasks(tasks)
            case None => ()
        }

        match (memoryTasks) {
            case Some(tasks) => return cloneTasks(tasks)
            case None => ()
        }

        match (readTasksFile(tasksFile)) {
            case Some(tasks) =>
                memoryTasks = Some(cloneTasks(tasks))
                TASK_STORE_PROCESS_CACHE[storageKey] = cloneTasks(tasks)
                return tasks
            case None => ()
        }

        match (readTasksFile(tasksBackupFile)) {
            case Some(tasks) =>
                memoryTasks = Some(cloneTasks(tasks))
                TASK_STORE_PROCESS_CACHE[storageKey] = cloneTasks(tasks)
                return tasks
            case None => return ArrayList<Task>()
        }
    }

    public func saveTasks(tasks: ArrayList<Task>): Unit {
        memoryTasks = Some(cloneTasks(tasks))
        TASK_STORE_PROCESS_CACHE[storageKey] = cloneTasks(tasks)
        try {
            ensureDirectory(storageDir)
            let encoded = TaskCoreJson.encodeTasks(tasks).toArray()
            File.writeTo(tasksBackupFile, encoded)
            File.writeTo(tasksFile, encoded)
        } catch (e: Exception) {
            ()
        }
    }

    public func upsertTask(task: Task): Unit {
        let tasks = loadTasks()
        var replaced = false
        for (i in 0..tasks.size) {
            if (tasks[i].id == task.id) {
                tasks[i] = task
                replaced = true
                break
            }
        }
        if (!replaced) {
            tasks.append(task)
        }
        saveTasks(tasks)
    }

    public func findTask(taskId: String): Option<Task> {
        for (task in loadTasks()) {
            if (task.id == taskId) {
                return Some(task)
            }
        }
        return None
    }

    public func removeTask(taskId: String): Unit {
        let tasks = loadTasks()
        var removed = false
        var index: Int64 = 0
        while (index < tasks.size) {
            if (tasks[index].id == taskId) {
                tasks.remove(index)
                removed = true
                break
            }
            index += 1
        }
        if (removed) {
            saveTasks(tasks)
        }
    }

    private func readTasksFile(path: Path): Option<ArrayList<Task>> {
        try {
            let text = String.fromUtf8(File.readFrom(path))
            let trimmed = text.trimAscii()
            if (trimmed.size == 0) {
                return None
            }
            let tasks = TaskCoreJson.decodeTasks(text)
            if (tasks.size == 0 && trimmed != "[]") {
                return None
            }
            return Some(tasks)
        } catch (e: Exception) {
            return None
        }
    }
}

public class ServerStore {
    private let storageDir: Path
    private let serversFile: Path
    private var memoryServers: Option<ArrayList<ServerConfig>> = None

    public init() {
        let base = taskCoreStoragePath(".cc-mobile-local")
        this.storageDir = base
        this.serversFile = base.join("servers.json")
        ensureDirectory(base)
    }

    public init(storageDir: String) {
        let base = taskCoreStoragePath(storageDir)
        this.storageDir = base
        this.serversFile = base.join("servers.json")
        ensureDirectory(base)
    }

    public func loadServers(): ArrayList<ServerConfig> {
        match (memoryServers) {
            case Some(servers) => return cloneServers(servers)
            case None => ()
        }

        try {
            let servers = TaskCoreJson.decodeServers(String.fromUtf8(File.readFrom(serversFile)))
            memoryServers = Some(cloneServers(servers))
            return servers
        } catch (e: Exception) {
            return ArrayList<ServerConfig>()
        }
    }

    public func saveServers(servers: ArrayList<ServerConfig>): Unit {
        memoryServers = Some(cloneServers(servers))
        try {
            ensureDirectory(storageDir)
            File.writeTo(serversFile, TaskCoreJson.encodeServers(servers).toArray())
        } catch (e: Exception) {
            ()
        }
    }

    public func getDefaultServer(): Option<ServerConfig> {
        let servers = loadServers()
        if (servers.size == 0) {
            return None
        }
        return Some(servers[0])
    }

    public func upsertServer(server: ServerConfig): Unit {
        let servers = loadServers()
        var replaced = false
        for (i in 0..servers.size) {
            if (servers[i].id == server.id) {
                servers[i] = server
                replaced = true
                break
            }
        }
        if (!replaced) {
            servers.append(server)
        }
        saveServers(servers)
    }
}

public class TaskService {
    private let taskStore: TaskStore
    private let gateway: RemoteTaskGateway

    public init(taskStore: TaskStore, gateway: RemoteTaskGateway) {
        this.taskStore = taskStore
        this.gateway = gateway
    }

    public func submitTask(
        server: ServerConfig,
        repoPath: String,
        title: String,
        prompt: String,
        mode: RunMode
    ): Result<Task> {
        let error = validateTaskInput(repoPath, title, prompt)
        if (error.size > 0) {
            return taskFail<Task>(error)
        }

        let now = taskCoreNowSeconds()
        let taskId = generateTaskId()
        let task = Task(
            taskId,
            title.trimAscii(),
            prompt,
            server.id,
            repoPath.trimAscii(),
            deriveBranchName(taskId),
            deriveWorktreePath(taskId),
            deriveTmuxSession(taskId),
            deriveRemoteTaskDir(taskId),
            TaskStatus.local_created,
            mode,
            now,
            now,
            0,
            None
        )
        taskStore.upsertTask(task)

        let created = gateway.createTask(task, wrapPrompt(prompt, mode))
        if (!created.isOk) {
            task.lastError = resultMessage(created)
            task.updatedAt = taskCoreNowSeconds()
            taskStore.upsertTask(task)
            return taskFail<Task>(resultMessageText(created))
        }

        task.status = TaskStatus.worktree_created
        task.updatedAt = taskCoreNowSeconds()
        taskStore.upsertTask(task)

        let started = gateway.startTask(task)
        if (!started.isOk) {
            task.lastError = resultMessage(started)
            task.updatedAt = taskCoreNowSeconds()
            taskStore.upsertTask(task)
            return taskFail<Task>(resultMessageText(started))
        }

        task.status = TaskStatus.running
        task.updatedAt = taskCoreNowSeconds()
        task.lastError = None
        taskStore.upsertTask(task)
        return taskOk<Task>(task)
    }

    public func submitTask(server: ServerConfig, repoPath: String, title: String, prompt: String): Result<Task> {
        return submitTask(server, repoPath, title, prompt, RunMode.run)
    }

    public func refreshTasks(server: ServerConfig): Result<ArrayList<Task>> {
        let remoteRowsResult = gateway.listTasks(server)
        if (!remoteRowsResult.isOk) {
            return taskFail<ArrayList<Task>>(resultMessageText(remoteRowsResult))
        }

        let tasks = taskStore.loadTasks()
        let remoteRows = remoteRowsResult.value.getOrThrow()
        let seen = HashMap<String, Bool>()
        for (row in remoteRows) {
            seen[row.taskId] = true
            match (findTaskInMemory(tasks, row.taskId)) {
                case Some(task) =>
                    if (!isDeleted(task.status)) {
                        applyRemoteRow(task, row)
                    }
                case None =>
                    tasks.append(taskFromRemoteRow(row, server.id))
            }
        }

        for (task in tasks) {
            if (task.serverId == server.id && !seen.contains(task.id) && !isDeleted(task.status)) {
                task.status = TaskStatus.unknown
                task.updatedAt = taskCoreNowSeconds()
            }
        }

        taskStore.saveTasks(tasks)
        return taskOk<ArrayList<Task>>(visibleTasks(tasks, server.id))
    }

    public func refreshTask(taskId: String): Result<TaskDetail> {
        let task = match (taskStore.findTask(taskId)) {
            case Some(value) => value
            case None => return taskFail<TaskDetail>("Task not found: ${taskId}")
        }

        let remoteStatus = gateway.getTaskStatus(taskId)
        if (!remoteStatus.isOk) {
            task.status = TaskStatus.unknown
            task.lastError = resultMessage(remoteStatus)
            task.updatedAt = taskCoreNowSeconds()
            taskStore.upsertTask(task)
            return taskFail<TaskDetail>(resultMessageText(remoteStatus))
        }

        let status = remoteStatus.value.getOrThrow()
        applyRemoteStatus(task, status)

        let logResult = gateway.tailLog(taskId, 200)
        let stderrResult = gateway.tailStderr(taskId)
        if (!logResult.isOk) {
            task.lastError = resultMessage(logResult)
        } else if (!stderrResult.isOk) {
            task.lastError = resultMessage(stderrResult)
        } else {
            task.lastError = None
        }
        task.updatedAt = taskCoreNowSeconds()
        taskStore.upsertTask(task)

        return taskOk<TaskDetail>(TaskDetail(
            task,
            resultStringOrEmpty(logResult),
            resultStringOrEmpty(stderrResult),
            status.live,
            status.exitCode
        ))
    }

    public func stopTask(taskId: String): Result<Unit> {
        let task = match (taskStore.findTask(taskId)) {
            case Some(value) => value
            case None => return taskFail<Unit>("Task not found: ${taskId}")
        }
        let stopped = gateway.stopTask(taskId)
        if (!stopped.isOk) {
            task.lastError = resultMessage(stopped)
            task.updatedAt = taskCoreNowSeconds()
            taskStore.upsertTask(task)
            return taskFail<Unit>(resultMessageText(stopped))
        }
        task.status = TaskStatus.stopped
        task.lastError = None
        task.updatedAt = taskCoreNowSeconds()
        taskStore.upsertTask(task)
        return taskOk<Unit>(())
    }

    public func deleteTask(taskId: String): Result<Unit> {
        let task = match (taskStore.findTask(taskId)) {
            case Some(value) => value
            case None => return taskFail<Unit>("Task not found: ${taskId}")
        }
        let deleted = gateway.deleteTask(taskId)
        if (!deleted.isOk) {
            task.lastError = resultMessage(deleted)
            task.updatedAt = taskCoreNowSeconds()
            taskStore.upsertTask(task)
            return taskFail<Unit>(resultMessageText(deleted))
        }
        taskStore.removeTask(taskId)
        return taskOk<Unit>(())
    }

    public func loadGitSummary(taskId: String): Result<String> {
        if (let None <- taskStore.findTask(taskId)) {
            return taskFail<String>("Task not found: ${taskId}")
        }
        return gateway.gitSummary(taskId)
    }
}

public class FakeRemoteTaskGateway <: RemoteTaskGateway {
    public var failInit: Bool = false
    public var failCreate: Bool = false
    public var failStart: Bool = false
    public var failList: Bool = false
    public var failStatus: Bool = false
    public var failStop: Bool = false
    public var failDelete: Bool = false
    public var failGitSummary: Bool = false
    public var createCallCount: Int64 = 0
    public var startCallCount: Int64 = 0
    public var stopCallCount: Int64 = 0
    public var deleteCallCount: Int64 = 0
    public let wrappedPrompts = HashMap<String, String>()

    private let tasks = HashMap<String, RemoteTaskStatus>()
    private let logs = HashMap<String, String>()
    private let stderrs = HashMap<String, String>()
    private var gitText: String = "--- STATUS ---\n M fake.cj\n\n--- DIFF STAT ---\nfake.cj | 1 +\n\n--- RECENT COMMITS ---\nabc123 fake\n"

    public init() {}

    public func initRemote(server: ServerConfig): Result<InitResult> {
        let _ = server
        if (failInit) {
            return taskFail<InitResult>("fake initRemote failed")
        }
        return taskOk<InitResult>(InitResult("ok"))
    }

    public func createTask(task: Task, wrappedPrompt: String): Result<Unit> {
        createCallCount += 1
        if (failCreate) {
            return taskFail<Unit>("fake createTask failed")
        }
        wrappedPrompts[task.id] = wrappedPrompt
        tasks[task.id] = RemoteTaskStatus(
            task.id,
            task.title,
            TaskStatus.worktree_created,
            false,
            None,
            task.repoPath,
            task.worktreePath,
            task.branchName,
            task.tmuxSession
        )
        logs[task.id] = "created ${task.id}"
        stderrs[task.id] = ""
        return taskOk<Unit>(())
    }

    public func startTask(task: Task): Result<Unit> {
        startCallCount += 1
        if (failStart) {
            return taskFail<Unit>("fake startTask failed")
        }
        tasks[task.id] = RemoteTaskStatus(
            task.id,
            task.title,
            TaskStatus.running,
            true,
            None,
            task.repoPath,
            task.worktreePath,
            task.branchName,
            task.tmuxSession
        )
        logs[task.id] = "running ${task.id}"
        return taskOk<Unit>(())
    }

    public func listTasks(server: ServerConfig): Result<ArrayList<RemoteTaskRow>> {
        let _ = server
        if (failList) {
            return taskFail<ArrayList<RemoteTaskRow>>("fake listTasks failed")
        }
        let rows = ArrayList<RemoteTaskRow>()
        for ((_, status) in tasks) {
            rows.append(RemoteTaskRow(
                status.taskId,
                status.title,
                status.status,
                status.live,
                status.exitCode,
                status.repo,
                status.branch,
                status.worktree
            ))
        }
        return taskOk<ArrayList<RemoteTaskRow>>(rows)
    }

    public func getTaskStatus(taskId: String): Result<RemoteTaskStatus> {
        if (failStatus) {
            return taskFail<RemoteTaskStatus>("fake getTaskStatus failed")
        }
        match (tasks.get(taskId)) {
            case Some(status) => return taskOk<RemoteTaskStatus>(status)
            case None => return taskFail<RemoteTaskStatus>("fake task not found: ${taskId}")
        }
    }

    public func tailLog(taskId: String, lines: Int64): Result<String> {
        let _ = lines
        return taskOk<String>(logs.get(taskId) ?? "")
    }

    public func tailStderr(taskId: String): Result<String> {
        return taskOk<String>(stderrs.get(taskId) ?? "")
    }

    public func stopTask(taskId: String): Result<Unit> {
        stopCallCount += 1
        if (failStop) {
            return taskFail<Unit>("fake stopTask failed")
        }
        match (tasks.get(taskId)) {
            case Some(status) =>
                tasks[taskId] = cloneRemoteStatus(status, TaskStatus.stopped, false, status.exitCode)
            case None => ()
        }
        return taskOk<Unit>(())
    }

    public func deleteTask(taskId: String): Result<Unit> {
        deleteCallCount += 1
        if (failDelete) {
            return taskFail<Unit>("fake deleteTask failed")
        }
        tasks.remove(taskId)
        logs.remove(taskId)
        stderrs.remove(taskId)
        return taskOk<Unit>(())
    }

    public func gitSummary(taskId: String): Result<String> {
        let _ = taskId
        if (failGitSummary) {
            return taskFail<String>("fake gitSummary failed")
        }
        return taskOk<String>(gitText)
    }

    public func setRemoteStatus(status: RemoteTaskStatus): Unit {
        tasks[status.taskId] = status
    }

    public func setLog(taskId: String, text: String): Unit {
        logs[taskId] = text
    }

    public func setStderr(taskId: String, text: String): Unit {
        stderrs[taskId] = text
    }

    public func setGitSummary(text: String): Unit {
        gitText = text
    }
}

public func wrapPrompt(prompt: String, mode: RunMode): String {
    let sb = StringBuilder()
    sb.append("你正在一个独立 git worktree 中工作。\n\n")
    sb.append("任务：\n")
    sb.append(prompt)
    sb.append("\n\n要求：\n")
    sb.append("1. 先快速理解项目结构。\n")
    sb.append("2. 尽量小步修改。\n")
    sb.append("3. 修改后运行相关测试或构建命令。\n")
    sb.append("4. 如果测试失败，继续修复。\n")
    sb.append("5. 重要决策写入 PROGRESS.md。\n")
    sb.append("6. 完成后创建一个 git commit，commit message 要清晰。\n")
    sb.append("7. 不要修改与任务无关的文件。\n")
    sb.append("8. 完成后退出。\n")
    if (isPlanMode(mode)) {
        sb.append("\n本次任务只做计划，不直接修改代码。请输出实施步骤、风险点、建议拆分方式。\n")
    }
    return sb.toString()
}

public func generateTaskId(): String {
    let timestamp = formatTaskIdTimestamp(DateTime.now())
    let suffix = leftPad(Random().nextInt64(1000000).toString(), 6, "0")
    return "ccm-${timestamp}-${suffix}"
}

public func isValidTaskId(taskId: String): Bool {
    if (taskId.size == 0) {
        return false
    }
    for (b in taskId.toArray()) {
        let ok = (b >= b'a' && b <= b'z') || (b >= b'A' && b <= b'Z') || (b >= b'0' && b <= b'9') ||
            b == b'_' || b == b'-'
        if (!ok) {
            return false
        }
    }
    return true
}

public func deriveBranchName(taskId: String): String {
    return "agent/${taskId}"
}

public func deriveTmuxSession(taskId: String): String {
    return "cc-${taskId}"
}

public func deriveRemoteTaskDir(taskId: String): String {
    return "$HOME/.cc-mobile/tasks/${taskId}"
}

public func deriveWorktreePath(taskId: String): String {
    return "$HOME/.cc-mobile/worktrees/${taskId}"
}

public func taskStatusToWire(status: TaskStatus): String {
    match (status) {
        case TaskStatus.local_created => "local_created"
        case TaskStatus.remote_created => "remote_created"
        case TaskStatus.worktree_created => "worktree_created"
        case TaskStatus.running => "running"
        case TaskStatus.completed => "completed"
        case TaskStatus.failed => "failed"
        case TaskStatus.stopped => "stopped"
        case TaskStatus.unknown => "unknown"
        case TaskStatus.deleted => "deleted"
    }
}

public func taskStatusFromWire(value: String): TaskStatus {
    match (value) {
        case "local_created" => TaskStatus.local_created
        case "remote_created" => TaskStatus.remote_created
        case "worktree_created" => TaskStatus.worktree_created
        case "running" => TaskStatus.running
        case "completed" => TaskStatus.completed
        case "failed" => TaskStatus.failed
        case "stopped" => TaskStatus.stopped
        case "deleted" => TaskStatus.deleted
        case _ => TaskStatus.unknown
    }
}

private func validateTaskInput(repoPath: String, title: String, prompt: String): String {
    if (repoPath.trimAscii().size == 0) {
        return "repoPath cannot be empty"
    }
    if (title.trimAscii().size == 0) {
        return "title cannot be empty"
    }
    if (prompt.trimAscii().size == 0) {
        return "prompt cannot be empty"
    }
    return ""
}

private func taskCoreNowSeconds(): Int64 {
    return DateTime.now().toUnixTimeStamp().toSeconds()
}

private func leftPad(value: String, width: Int64, pad: String): String {
    var out = value
    while (out.size < width) {
        out = pad + out
    }
    return out
}

private func formatTaskIdTimestamp(value: DateTime): String {
    return "${leftPad(value.year.toString(), 4, "0")}${monthToDigits(value.month)}${leftPad(value.dayOfMonth.toString(), 2, "0")}-${leftPad(value.hour.toString(), 2, "0")}${leftPad(value.minute.toString(), 2, "0")}${leftPad(value.second.toString(), 2, "0")}"
}

private func monthToDigits(value: Month): String {
    match (value) {
        case January => "01"
        case February => "02"
        case March => "03"
        case April => "04"
        case May => "05"
        case June => "06"
        case July => "07"
        case August => "08"
        case September => "09"
        case October => "10"
        case November => "11"
        case December => "12"
    }
}

private func isPlanMode(mode: RunMode): Bool {
    match (mode) {
        case RunMode.plan => true
        case RunMode.run => false
    }
}

private func ensureDirectory(path: Path): Unit {
    try {
        Directory.create(path, recursive: true)
    } catch (e: Exception) {
        ()
    }
}

private func taskCoreStoragePath(storageDir: String): Path {
    let path = Path(storageDir)
    if (path.isAbsolute()) {
        return path
    }
    return Path("/data/storage/el2/base/files").join(storageDir)
}

private func runModeToWire(mode: RunMode): String {
    match (mode) {
        case RunMode.plan => "plan"
        case RunMode.run => "run"
    }
}

private func runModeFromWire(value: String): RunMode {
    match (value) {
        case "plan" => RunMode.plan
        case _ => RunMode.run
    }
}

private func isDeleted(status: TaskStatus): Bool {
    match (status) {
        case TaskStatus.deleted => true
        case _ => false
    }
}

private func isTerminal(status: TaskStatus): Bool {
    match (status) {
        case TaskStatus.completed => true
        case TaskStatus.failed => true
        case TaskStatus.stopped => true
        case TaskStatus.deleted => true
        case _ => false
    }
}

private func normalizedRemoteStatus(status: TaskStatus, live: Bool, exitCode: Option<Int64>): TaskStatus {
    match (status) {
        case TaskStatus.unknown =>
            match (exitCode) {
                case Some(code) => return if (code == 0) { TaskStatus.completed } else { TaskStatus.failed }
                case None => return if (live) { TaskStatus.running } else { TaskStatus.unknown }
            }
        case _ =>
            if (live && !isTerminal(status)) {
                return TaskStatus.running
            }
            return status
    }
}

private func applyRemoteRow(task: Task, row: RemoteTaskRow): Unit {
    task.status = normalizedRemoteStatus(row.status, row.live, row.exitCode)
    applyRemoteTitle(task, row.title)
    task.repoPath = row.repo
    task.branchName = row.branch
    task.worktreePath = row.worktree
    task.tmuxSession = deriveTmuxSession(row.taskId)
    task.remoteTaskDir = deriveRemoteTaskDir(row.taskId)
    task.updatedAt = taskCoreNowSeconds()
}

private func applyRemoteStatus(task: Task, status: RemoteTaskStatus): Unit {
    task.status = normalizedRemoteStatus(status.status, status.live, status.exitCode)
    applyRemoteTitle(task, status.title)
    task.repoPath = status.repo
    task.worktreePath = status.worktree
    task.branchName = status.branch
    task.tmuxSession = status.tmux
    task.remoteTaskDir = deriveRemoteTaskDir(status.taskId)
    task.updatedAt = taskCoreNowSeconds()
}

private func taskFromRemoteRow(row: RemoteTaskRow, serverId: String): Task {
    let now = taskCoreNowSeconds()
    return Task(
        row.taskId,
        fallbackTaskTitle(row.taskId, row.title),
        "",
        serverId,
        row.repo,
        row.branch,
        row.worktree,
        deriveTmuxSession(row.taskId),
        deriveRemoteTaskDir(row.taskId),
        normalizedRemoteStatus(row.status, row.live, row.exitCode),
        RunMode.run,
        now,
        now,
        0,
        None
    )
}

private func findTaskInMemory(tasks: ArrayList<Task>, taskId: String): Option<Task> {
    for (task in tasks) {
        if (task.id == taskId) {
            return Some(task)
        }
    }
    return None
}

private func visibleTasks(tasks: ArrayList<Task>, serverId: String): ArrayList<Task> {
    let out = ArrayList<Task>()
    for (task in tasks) {
        if (task.serverId == serverId && !isDeleted(task.status)) {
            out.append(task)
        }
    }
    return out
}

private func resultMessage<T>(result: Result<T>): Option<String> {
    return result.error
}

private func resultMessageText<T>(result: Result<T>): String {
    return result.error ?? "unknown error"
}

private func resultStringOrEmpty(result: Result<String>): String {
    return result.value ?? ""
}

private func cloneRemoteStatus(
    source: RemoteTaskStatus,
    status: TaskStatus,
    live: Bool,
    exitCode: Option<Int64>
): RemoteTaskStatus {
    return RemoteTaskStatus(
        source.taskId,
        source.title,
        status,
        live,
        exitCode,
        source.repo,
        source.worktree,
        source.branch,
        source.tmux
    )
}

private func applyRemoteTitle(task: Task, title: String): Unit {
    let cleaned = title.trimAscii()
    if (cleaned.size > 0 && (task.title.size == 0 || task.title == task.id)) {
        task.title = cleaned
    }
}

private func fallbackTaskTitle(taskId: String, title: String): String {
    let cleaned = title.trimAscii()
    if (cleaned.size > 0) {
        return cleaned
    }
    return taskId
}

private func cloneTask(task: Task): Task {
    return Task(
        task.id,
        task.title,
        task.prompt,
        task.serverId,
        task.repoPath,
        task.branchName,
        task.worktreePath,
        task.tmuxSession,
        task.remoteTaskDir,
        task.status,
        task.mode,
        task.createdAt,
        task.updatedAt,
        task.lastLogOffset,
        task.lastError
    )
}

private func cloneTasks(tasks: ArrayList<Task>): ArrayList<Task> {
    let out = ArrayList<Task>()
    for (task in tasks) {
        out.append(cloneTask(task))
    }
    return out
}

private func cloneServer(server: ServerConfig): ServerConfig {
    return ServerConfig(
        server.id,
        server.name,
        server.host,
        server.port,
        server.username,
        server.passwordRef,
        server.defaultRepoPath,
        server.createdAt,
        server.updatedAt
    )
}

private func cloneServers(servers: ArrayList<ServerConfig>): ArrayList<ServerConfig> {
    let out = ArrayList<ServerConfig>()
    for (server in servers) {
        out.append(cloneServer(server))
    }
    return out
}

class TaskCoreJson {
    public static func encodeTasks(tasks: ArrayList<Task>): String {
        let array = JsonArray()
        for (task in tasks) {
            array.add(encodeTask(task))
        }
        return array.toJsonString()
    }

    public static func decodeTasks(text: String): ArrayList<Task> {
        let tasks = ArrayList<Task>()
        try {
            let array = JsonValue.fromStr(text).asArray()
            for (i in 0..array.size()) {
                try {
                    let task = decodeTask(array[i].asObject())
                    if (task.id.size > 0) {
                        tasks.append(task)
                    }
                } catch (e: Exception) {
                    ()
                }
            }
        } catch (e: Exception) {
            ()
        }
        return tasks
    }

    public static func encodeServers(servers: ArrayList<ServerConfig>): String {
        let array = JsonArray()
        for (server in servers) {
            array.add(encodeServer(server))
        }
        return array.toJsonString()
    }

    public static func decodeServers(text: String): ArrayList<ServerConfig> {
        let servers = ArrayList<ServerConfig>()
        try {
            let array = JsonValue.fromStr(text).asArray()
            for (i in 0..array.size()) {
                try {
                    let server = decodeServer(array[i].asObject())
                    if (server.id.size > 0) {
                        servers.append(server)
                    }
                } catch (e: Exception) {
                    ()
                }
            }
        } catch (e: Exception) {
            ()
        }
        return servers
    }

    private static func encodeTask(task: Task): JsonObject {
        let obj = JsonObject()
        obj.put("id", JsonString(task.id))
        obj.put("title", JsonString(task.title))
        obj.put("prompt", JsonString(task.prompt))
        obj.put("serverId", JsonString(task.serverId))
        obj.put("repoPath", JsonString(task.repoPath))
        obj.put("branchName", JsonString(task.branchName))
        obj.put("worktreePath", JsonString(task.worktreePath))
        obj.put("tmuxSession", JsonString(task.tmuxSession))
        obj.put("remoteTaskDir", JsonString(task.remoteTaskDir))
        obj.put("status", JsonString(taskStatusToWire(task.status)))
        obj.put("mode", JsonString(runModeToWire(task.mode)))
        obj.put("createdAt", JsonInt(task.createdAt))
        obj.put("updatedAt", JsonInt(task.updatedAt))
        obj.put("lastLogOffset", JsonInt(task.lastLogOffset))
        obj.put("lastError", JsonString(task.lastError ?? ""))
        return obj
    }

    private static func decodeTask(obj: JsonObject): Task {
        let now = taskCoreNowSeconds()
        let lastError = stringField(obj, "lastError", "")
        return Task(
            stringField(obj, "id", ""),
            stringField(obj, "title", ""),
            stringField(obj, "prompt", ""),
            stringField(obj, "serverId", ""),
            stringField(obj, "repoPath", ""),
            stringField(obj, "branchName", ""),
            stringField(obj, "worktreePath", ""),
            stringField(obj, "tmuxSession", ""),
            stringField(obj, "remoteTaskDir", ""),
            taskStatusFromWire(stringField(obj, "status", "unknown")),
            runModeFromWire(stringField(obj, "mode", "run")),
            intField(obj, "createdAt", now),
            intField(obj, "updatedAt", now),
            intField(obj, "lastLogOffset", 0),
            if (lastError.size > 0) { Some(lastError) } else { None }
        )
    }

    private static func encodeServer(server: ServerConfig): JsonObject {
        let obj = JsonObject()
        obj.put("id", JsonString(server.id))
        obj.put("name", JsonString(server.name))
        obj.put("host", JsonString(server.host))
        obj.put("port", JsonInt(server.port))
        obj.put("username", JsonString(server.username))
        obj.put("passwordRef", JsonString(server.passwordRef))
        obj.put("defaultRepoPath", JsonString(server.defaultRepoPath))
        obj.put("createdAt", JsonInt(server.createdAt))
        obj.put("updatedAt", JsonInt(server.updatedAt))
        return obj
    }

    private static func decodeServer(obj: JsonObject): ServerConfig {
        let now = taskCoreNowSeconds()
        return ServerConfig(
            stringField(obj, "id", ""),
            stringField(obj, "name", ""),
            stringField(obj, "host", ""),
            intField(obj, "port", 22),
            stringField(obj, "username", ""),
            stringField(obj, "passwordRef", ""),
            stringField(obj, "defaultRepoPath", ""),
            intField(obj, "createdAt", now),
            intField(obj, "updatedAt", now)
        )
    }

    private static func stringField(obj: JsonObject, key: String, fallback: String): String {
        match (obj.get(key)) {
            case Some(value) =>
                try {
                    return value.asString().getValue()
                } catch (e: Exception) {
                    return fallback
                }
            case None => return fallback
        }
    }

    private static func intField(obj: JsonObject, key: String, fallback: Int64): Int64 {
        match (obj.get(key)) {
            case Some(value) =>
                try {
                    return value.asInt().getValue()
                } catch (e: Exception) {
                    return fallback
                }
            case None => return fallback
        }
    }
}
