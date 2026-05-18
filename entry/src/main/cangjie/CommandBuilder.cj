package ohos_app_cangjie_entry

/**
 * 任务运行模式。
 *
 * - run: 默认模式，使用 danger run 参数执行 Claude Code。
 * - plan: 规划模式，只做计划，不直接执行危险写操作。
 */
public enum RunMode {
    | plan
    | run
}

/**
 * 生成远端命令所需的输入参数。
 *
 * 说明：
 * - branchName / tmuxSession 在安全实现中不会直接信任用户输入；
 *   CommandBuilder 内部会按 taskId 派生规范值。
 * - worktreePath 在第一版固定为 ~/.cc-mobile/worktrees/<task_id>，
 *   该字段保留用于后续兼容扩展。
 */
class TaskCommandInput {
    let taskId: String
    let title: String
    let repoPath: String
    let worktreePath: String
    let branchName: String
    let tmuxSession: String
    let promptBase64: String
    let mode: RunMode

    public init(
        taskId: String,
        title: String,
        repoPath: String,
        worktreePath: String,
        branchName: String,
        tmuxSession: String,
        promptBase64: String,
        mode: RunMode
    ) {
        this.taskId = taskId
        this.title = title
        this.repoPath = repoPath
        this.worktreePath = worktreePath
        this.branchName = branchName
        this.tmuxSession = tmuxSession
        this.promptBase64 = promptBase64
        this.mode = mode
    }

    /**
     * 便捷构造：未显式指定 mode 时，默认按 run 模式处理。
     */
    public init(
        taskId: String,
        repoPath: String,
        worktreePath: String,
        branchName: String,
        tmuxSession: String,
        promptBase64: String
    ) {
        this.taskId = taskId
        this.title = ""
        this.repoPath = repoPath
        this.worktreePath = worktreePath
        this.branchName = branchName
        this.tmuxSession = tmuxSession
        this.promptBase64 = promptBase64
        this.mode = RunMode.run
    }
}

/**
 * 与 shell 转义、输入安全校验相关的工具函数。
 */
class ShellEscape {
    /**
     * 将任意字符串安全地包裹为 shell 单引号字面量。
     *
     * 规则示例：
     * - abc   -> 'abc'
     * - a'b   -> 'a'\''b'
     */
    public static func shellSingleQuote(s: String): String {
        return "'" + s.replace("'", "'\\''") + "'"
    }

    /**
     * 将普通文本编码为 Base64 字符串。
     *
     * 说明：
     * - 这里使用纯仓颉实现，避免额外依赖。
     * - 输入按 UTF-8 字节处理（String.toArray()）。
     * - 输出仅包含 Base64 标准字符与 '=' 补位。
     */
    public static func base64Encode(s: String): String {
        let bytes = s.toArray()
        if (bytes.size == 0) {
            return ""
        }

        // 使用函数内常量，避免顶层常量定义顺序导致“先使用后定义”编译错误。
        let base64Table: Array<String> = [
            "A", "B", "C", "D", "E", "F", "G", "H",
            "I", "J", "K", "L", "M", "N", "O", "P",
            "Q", "R", "S", "T", "U", "V", "W", "X",
            "Y", "Z", "a", "b", "c", "d", "e", "f",
            "g", "h", "i", "j", "k", "l", "m", "n",
            "o", "p", "q", "r", "s", "t", "u", "v",
            "w", "x", "y", "z", "0", "1", "2", "3",
            "4", "5", "6", "7", "8", "9", "+", "/"
        ]

        var out = ""
        var i: Int64 = 0

        while (i < bytes.size) {
            let b0 = Int64(bytes[i])
            i += 1

            let hasB1 = i < bytes.size
            let b1 = if (hasB1) {
                Int64(bytes[i])
            } else {
                0
            }
            if (hasB1) {
                i += 1
            }

            let hasB2 = i < bytes.size
            let b2 = if (hasB2) {
                Int64(bytes[i])
            } else {
                0
            }
            if (hasB2) {
                i += 1
            }

            let s0 = (b0 >> 2) & 63
            let s1 = ((b0 & 3) << 4) | ((b1 >> 4) & 15)
            let s2 = ((b1 & 15) << 2) | ((b2 >> 6) & 3)
            let s3 = b2 & 63

            out += base64Table[s0]
            out += base64Table[s1]
            out += if (hasB1) {
                base64Table[s2]
            } else {
                "="
            }
            out += if (hasB2) {
                base64Table[s3]
            } else {
                "="
            }
        }

        return out
    }

    /**
     * taskId 安全校验。
     *
     * 仅允许字符：a-z A-Z 0-9 _ -
     */
    public static func taskIdSafe(s: String): Bool {
        if (s.size == 0) {
            return false
        }

        for (b in s.toArray()) {
            let ok = (b >= b'a' && b <= b'z') || (b >= b'A' && b <= b'Z') || (b >= b'0' && b <= b'9') || b == b'_' ||
                b == b'-'
            if (!ok) {
                return false
            }
        }
        return true
    }

    /**
     * 远端路径基础安全校验。
     *
     * 目标：防止明显危险输入，不做复杂规范化。
     * 当前规则：
     * - 不允许空字符串
     * - 必须是绝对路径（以 / 开头）
     * - 不允许包含 ..
     * - 不允许换行、回车、NUL
     * - 不允许常见命令拼接符号 ; | & ` $ < >
     */
    public static func remotePathSafe(s: String): Bool {
        if (s.size == 0) {
            return false
        }
        if (!s.startsWith("/")) {
            return false
        }
        if (s.contains("..")) {
            return false
        }
        if (s.contains("\n") || s.contains("\r") || s.contains("\u{0000}")) {
            return false
        }

        for (b in s.toArray()) {
            if (b == b';' || b == b'|' || b == b'&' || b == b'`' || b == b'$' || b == b'<' || b == b'>') {
                return false
            }
        }
        return true
    }
}

/**
 * 远端脚本模板集合。
 *
 * 说明：
 * - 该类只负责返回“脚本文本”，不负责包裹 bash -lc。
 * - 所有需要注入 shell 字面量的值，都由调用方提前做 shellSingleQuote。
 */
class RemoteScripts {
    public static func initScript(): String {
        return """
set -euo pipefail

mkdir -p "$HOME/.cc-mobile/config"
mkdir -p "$HOME/.cc-mobile/tasks"
mkdir -p "$HOME/.cc-mobile/worktrees"
mkdir -p "$HOME/.cc-mobile/tmp"

for cmd in git tmux claude base64 bash; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf "missing_dependency:%s\\n" "$cmd" >&2
    exit 127
  fi
done

printf "ok\\n"
"""
    }

    public static func createTaskScript(
        taskIdQuoted: String,
        titleQuoted: String,
        repoQuoted: String,
        branchQuoted: String,
        tmuxQuoted: String,
        promptB64Quoted: String,
        modeQuoted: String
    ): String {
        return """
set -euo pipefail

TASK_ID=${taskIdQuoted}
TITLE_VALUE=${titleQuoted}
REPO=${repoQuoted}
ROOT="$HOME/.cc-mobile"
TASK_DIR="$ROOT/tasks/$TASK_ID"
WT_DIR="$ROOT/worktrees/$TASK_ID"
BRANCH=${branchQuoted}
TMUX=${tmuxQuoted}
PROMPT_B64=${promptB64Quoted}
MODE_VALUE=${modeQuoted}

mkdir -p "$TASK_DIR"
mkdir -p "$ROOT/worktrees"
printf "%s" "$PROMPT_B64" | base64 -d > "$TASK_DIR/prompt.txt"

{
  printf "TASK_ID=%q\\n" "$TASK_ID"
  printf "TITLE=%q\\n" "$TITLE_VALUE"
  printf "REPO=%q\\n" "$REPO"
  printf "WORKTREE=%q\\n" "$WT_DIR"
  printf "BRANCH=%q\\n" "$BRANCH"
  printf "TMUX=%q\\n" "$TMUX"
  printf "CREATED_AT=%q\\n" "$(date -Iseconds)"
  printf "MODE=%q\\n" "$MODE_VALUE"
} > "$TASK_DIR/meta.env"

printf "remote_created\\n" > "$TASK_DIR/status"

cd "$REPO"
git rev-parse --is-inside-work-tree >/dev/null

if [ -d "$WT_DIR" ]; then
  :
elif git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git worktree add "$WT_DIR" "$BRANCH"
else
  git worktree add -b "$BRANCH" "$WT_DIR"
fi

printf "worktree_created\\n" > "$TASK_DIR/status"
printf "%s\\n" "$TASK_ID"
"""
    }

    public static func startTaskScript(taskIdQuoted: String, mode: RunMode): String {
        let modeSelectScript = match (mode) {
            case RunMode.plan => """
CLAUDE_MODE_FLAG="--permission-mode plan"
"""
            case RunMode.run => """
CLAUDE_MODE_FLAG="--dangerously-skip-permissions"
if [ "$(id -u)" -eq 0 ]; then
  # 参考官方 issue 的常见做法：root/sudo 场景设置 IS_SANDBOX=1。
  export IS_SANDBOX=1
  echo "root_run_with_is_sandbox=1" >> "$TASK_DIR/stderr.log"
fi
"""
        }

        // 内层脚本：真正在远端运行，负责创建 runner.sh 并启动 tmux。
        let innerScript = """
set -euo pipefail

TASK_ID=${taskIdQuoted}
ROOT="$HOME/.cc-mobile"
TASK_DIR="$ROOT/tasks/$TASK_ID"
LOCK_DIR="$TASK_DIR/.start.lock"

[ -d "$TASK_DIR" ] || { echo "task_not_found" >&2; exit 1; }
[ -f "$TASK_DIR/meta.env" ] || { echo "meta_missing" >&2; exit 1; }
[ -f "$TASK_DIR/prompt.txt" ] || { echo "prompt_missing" >&2; exit 1; }

. "$TASK_DIR/meta.env"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if tmux has-session -t "$TMUX" 2>/dev/null; then
    echo "already_running"
    exit 0
  fi
  # Self-heal stale lock: if session is gone, remove lock and retry once.
  rmdir "$LOCK_DIR" 2>/dev/null || true
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "start_locked" >&2
    exit 1
  fi
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

if tmux has-session -t "$TMUX" 2>/dev/null; then
  echo "already_running"
  exit 0
fi

cat > "$TASK_DIR/runner.sh" <<'RUNNER'
set +e
if [ -z "$RUNNER_TASK_DIR" ]; then
  echo "runner_task_dir_missing" >&2
  exit 1
fi
if [ -z "$RUNNER_WORKTREE" ]; then
  echo "runner_worktree_missing" >&2
  exit 1
fi
TASK_DIR="$RUNNER_TASK_DIR"
WORKTREE="$RUNNER_WORKTREE"
cd "$WORKTREE" || exit 1

echo running > "$TASK_DIR/status"

${modeSelectScript}

claude -p "$(cat "$TASK_DIR/prompt.txt")" \\
  $CLAUDE_MODE_FLAG \\
  --output-format stream-json \\
  --verbose \\
  >> "$TASK_DIR/events.jsonl" \\
  2>> "$TASK_DIR/stderr.log"

CODE=$?
echo "$CODE" > "$TASK_DIR/exit.code"
if [ "$CODE" -eq 0 ]; then
  echo completed > "$TASK_DIR/status"
else
  echo failed > "$TASK_DIR/status"
fi
RUNNER

chmod +x "$TASK_DIR/runner.sh"
if tmux new-session -d -s "$TMUX" "env RUNNER_TASK_DIR=\"$TASK_DIR\" RUNNER_WORKTREE=\"$WORKTREE\" bash \"$TASK_DIR/runner.sh\"" 2>/dev/null; then
  echo "started"
elif tmux has-session -t "$TMUX" 2>/dev/null; then
  echo "already_running"
else
  echo "tmux_start_failed" >&2
  exit 1
fi
"""

        let innerB64 = ShellEscape.base64Encode(innerScript)

        // 外层脚本：通过 base64 传输脚本，避免复杂嵌套引号带来的转义风险。
        return """
set -euo pipefail

TASK_ID=${taskIdQuoted}
ROOT="$HOME/.cc-mobile"
TMP_SCRIPT="$ROOT/tmp/run-$TASK_ID.sh"
SCRIPT_B64=${ShellEscape
            .shellSingleQuote(innerB64)}

mkdir -p "$ROOT/tmp"
printf "%s" "$SCRIPT_B64" | base64 -d > "$TMP_SCRIPT"
bash "$TMP_SCRIPT"
"""
    }

    public static func listTasksScript(): String {
        return """
set -e
ROOT="$HOME/.cc-mobile/tasks"

if [ ! -d "$ROOT" ]; then
  exit 0
fi

for d in "$ROOT"/*; do
  [ -d "$d" ] || continue

  task_id=$(basename "$d")
  status=$(cat "$d/status" 2>/dev/null || echo unknown)
  exit_code=$(cat "$d/exit.code" 2>/dev/null || echo "")

  meta="$d/meta.env"
  repo=""
  branch=""
  worktree=""
  tmux_name=""
  title=""

  if [ -f "$meta" ]; then
    REPO=""
    BRANCH=""
    WORKTREE=""
    TMUX=""
    TITLE=""
    . "$meta"
    repo="$REPO"
    branch="$BRANCH"
    worktree="$WORKTREE"
    tmux_name="$TMUX"
    title="$TITLE"
  fi

  if [ -n "$tmux_name" ] && tmux has-session -t "$tmux_name" 2>/dev/null; then
    live="true"
  else
    live="false"
  fi

  printf "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n" \\
    "$task_id" "$status" "$live" "$exit_code" "$repo" "$branch" "$worktree" "$(printf "%s" "$title" | tr "\\t\\r\\n" "   ")"
done
"""
    }

    public static func taskStatusScript(taskIdQuoted: String): String {
        return """
set -euo pipefail

TASK_ID=${taskIdQuoted}
TASK_DIR="$HOME/.cc-mobile/tasks/$TASK_ID"
[ -d "$TASK_DIR" ] || { echo "not_found"; exit 1; }

STATUS=$(cat "$TASK_DIR/status" 2>/dev/null || echo unknown)
EXIT_CODE=$(cat "$TASK_DIR/exit.code" 2>/dev/null || echo "")
TITLE=""
. "$TASK_DIR/meta.env"

if tmux has-session -t "$TMUX" 2>/dev/null; then
  LIVE=true
else
  LIVE=false
fi

printf "task_id=%s\\n" "$TASK_ID"
printf "title=%s\\n" "$(printf "%s" "$TITLE" | tr "\\r\\n" "  ")"
printf "status=%s\\n" "$STATUS"
printf "live=%s\\n" "$LIVE"
printf "exit_code=%s\\n" "$EXIT_CODE"
printf "repo=%s\\n" "$REPO"
printf "worktree=%s\\n" "$WORKTREE"
printf "branch=%s\\n" "$BRANCH"
printf "tmux=%s\\n" "$TMUX"
"""
    }

    public static func tailLogScript(taskIdQuoted: String, lines: Int64): String {
        return """
set -e
TASK_ID=${taskIdQuoted}
LOG="$HOME/.cc-mobile/tasks/$TASK_ID/events.jsonl"
[ -f "$LOG" ] || exit 0
tail -n ${lines} "$LOG"
"""
    }

    public static func tailStderrScript(taskIdQuoted: String): String {
        return """
set -e
TASK_ID=${taskIdQuoted}
LOG="$HOME/.cc-mobile/tasks/$TASK_ID/stderr.log"
[ -f "$LOG" ] || exit 0
tail -n 100 "$LOG"
"""
    }

    public static func gitSummaryScript(taskIdQuoted: String): String {
        return """
set -euo pipefail

TASK_ID=${taskIdQuoted}
. "$HOME/.cc-mobile/tasks/$TASK_ID/meta.env"
cd "$WORKTREE"

echo "--- STATUS ---"
git status --short

printf "\\n--- DIFF STAT ---\\n"
git diff --stat

printf "\\n--- RECENT COMMITS ---\\n"
git log --oneline -5
"""
    }

    public static func stopTaskScript(taskIdQuoted: String): String {
        return """
set -euo pipefail

TASK_ID=${taskIdQuoted}
TASK_DIR="$HOME/.cc-mobile/tasks/$TASK_ID"
[ -d "$TASK_DIR" ] || { echo "not_found"; exit 1; }

. "$TASK_DIR/meta.env"
if tmux has-session -t "$TMUX" 2>/dev/null; then
  tmux kill-session -t "$TMUX"
fi

echo stopped > "$TASK_DIR/status"
echo stopped
"""
    }

    public static func deleteTaskScript(taskIdQuoted: String): String {
        return """
set -euo pipefail

TASK_ID=${taskIdQuoted}
ROOT="$HOME/.cc-mobile"
TASK_DIR="$ROOT/tasks/$TASK_ID"
EXPECTED_WT="$ROOT/worktrees/$TASK_ID"
[ -d "$TASK_DIR" ] || { echo "not_found"; exit 0; }
[ -f "$TASK_DIR/meta.env" ] || { echo "meta_missing" >&2; exit 1; }

. "$TASK_DIR/meta.env"

if [ -n "$TMUX" ] && tmux has-session -t "$TMUX" 2>/dev/null; then
  tmux kill-session -t "$TMUX"
fi

if [ "$WORKTREE" != "$EXPECTED_WT" ]; then
  echo "unsafe_worktree:$WORKTREE" >&2
  exit 1
fi

if [ -n "$REPO" ] && git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  cd "$REPO"
  git worktree remove --force "$WORKTREE" 2>/dev/null || true
  git worktree prune || true
fi

if [ -d "$WORKTREE" ]; then
  rm -rf "$WORKTREE"
fi

if [ -n "$REPO" ] && git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  cd "$REPO"
  git worktree prune || true
fi

rm -rf "$TASK_DIR"
echo deleted
"""
    }
}

/**
 * 对外命令构建入口。
 *
 * 所有方法都返回完整的可执行命令字符串，统一使用 `bash -lc '<script>'` 形式。
 */
class CommandBuilder {
    public init() {}

    /**
     * 构建远端初始化命令。
     */
    public func buildInitCommand(): String {
        return wrapBashLc(RemoteScripts.initScript())
    }

    /**
     * 构建“创建任务目录 + 写入元信息 + 创建 worktree”的命令。
     */
    public func buildCreateTaskCommand(input: TaskCommandInput): String {
        if (!ShellEscape.taskIdSafe(input.taskId)) {
            return buildRejectCommand("invalid task_id")
        }
        if (!ShellEscape.remotePathSafe(input.repoPath)) {
            return buildRejectCommand("invalid repo_path")
        }

        let branch = "agent/${input.taskId}"
        let tmux = "cc-${input.taskId}"

        let modeValue = match (input.mode) {
            case RunMode.plan => "plan"
            case RunMode.run => "run"
        }

        let script = RemoteScripts.createTaskScript(
            ShellEscape.shellSingleQuote(input.taskId),
            ShellEscape.shellSingleQuote(input.title),
            ShellEscape.shellSingleQuote(input.repoPath),
            ShellEscape.shellSingleQuote(branch),
            ShellEscape.shellSingleQuote(tmux),
            ShellEscape.shellSingleQuote(input.promptBase64),
            ShellEscape.shellSingleQuote(modeValue)
        )
        return wrapBashLc(script)
    }

    /**
     * 构建“启动任务（tmux + runner.sh）”命令。
     */
    public func buildStartTaskCommand(input: TaskCommandInput): String {
        if (!ShellEscape.taskIdSafe(input.taskId)) {
            return buildRejectCommand("invalid task_id")
        }

        let script = RemoteScripts.startTaskScript(ShellEscape.shellSingleQuote(input.taskId), input.mode)
        return wrapBashLc(script)
    }

    /**
     * 构建任务列表命令（TSV 输出）。
     */
    public func buildListTasksCommand(): String {
        return wrapBashLc(RemoteScripts.listTasksScript())
    }

    /**
     * 构建单任务状态命令（key=value 输出）。
     */
    public func buildTaskStatusCommand(taskId: String): String {
        if (!ShellEscape.taskIdSafe(taskId)) {
            return buildRejectCommand("invalid task_id")
        }
        return wrapBashLc(RemoteScripts.taskStatusScript(ShellEscape.shellSingleQuote(taskId)))
    }

    /**
     * 构建任务日志 tail 命令。
     */
    public func buildTailLogCommand(taskId: String, lines: Int64): String {
        if (!ShellEscape.taskIdSafe(taskId)) {
            return buildRejectCommand("invalid task_id")
        }

        // 保护性处理：限制行数范围，避免一次拉取过大。
        var safeLines = lines
        if (safeLines <= 0) {
            safeLines = 200
        }
        if (safeLines > 5000) {
            safeLines = 5000
        }

        return wrapBashLc(RemoteScripts.tailLogScript(ShellEscape.shellSingleQuote(taskId), safeLines))
    }

    /**
     * 构建 stderr tail 命令，固定读取最近 100 行。
     */
    public func buildTailStderrCommand(taskId: String): String {
        if (!ShellEscape.taskIdSafe(taskId)) {
            return buildRejectCommand("invalid task_id")
        }
        return wrapBashLc(RemoteScripts.tailStderrScript(ShellEscape.shellSingleQuote(taskId)))
    }

    /**
     * 构建 git 摘要命令。
     */
    public func buildGitSummaryCommand(taskId: String): String {
        if (!ShellEscape.taskIdSafe(taskId)) {
            return buildRejectCommand("invalid task_id")
        }
        return wrapBashLc(RemoteScripts.gitSummaryScript(ShellEscape.shellSingleQuote(taskId)))
    }

    /**
     * 构建停止任务命令。
     */
    public func buildStopTaskCommand(taskId: String): String {
        if (!ShellEscape.taskIdSafe(taskId)) {
            return buildRejectCommand("invalid task_id")
        }
        return wrapBashLc(RemoteScripts.stopTaskScript(ShellEscape.shellSingleQuote(taskId)))
    }

    /**
     * 构建删除命令：停止 tmux，删除任务目录与 worktree，但保留 git branch。
     */
    public func buildDeleteTaskCommand(taskId: String): String {
        if (!ShellEscape.taskIdSafe(taskId)) {
            return buildRejectCommand("invalid task_id")
        }
        return wrapBashLc(RemoteScripts.deleteTaskScript(ShellEscape.shellSingleQuote(taskId)))
    }

    /**
     * 统一包装为 bash -lc 命令。
     */
    private func wrapBashLc(script: String): String {
        return "bash -lc " + ShellEscape.shellSingleQuote(script)
    }

    /**
     * 对非法输入返回统一拒绝命令：
     * - stderr 输出原因
     * - 退出码 2
     */
    private func buildRejectCommand(reason: String): String {
        let script = """
set -e
printf "%s\\n" ${ShellEscape.shellSingleQuote(reason)} >&2
exit 2
"""
        return wrapBashLc(script)
    }
}
