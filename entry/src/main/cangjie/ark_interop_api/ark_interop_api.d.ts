export declare class CjResultLogPanel {
    ok: boolean
    msg: string
    raw: string
    data: CjLogPanelState | undefined
}

export declare class CjResultTaskDetail {
    ok: boolean
    msg: string
    raw: string
    data: CjTaskDetailState | undefined
}

export declare class CjResultTaskCard {
    ok: boolean
    msg: string
    raw: string
    data: CjTaskCardState | undefined
}

export declare class CjResultString {
    ok: boolean
    msg: string
    raw: string
    data: string
}

export declare class CjResultBool {
    ok: boolean
    msg: string
    raw: string
    data: boolean
}

export declare class CjLogPanelState {
    text: string
    raw: string
    stderr: string
}

export declare class CjTaskDetailState {
    title: string
    taskId: string
    status: string
    repo: string
    branch: string
    live: boolean
    createdAt: string
    updatedAt: string
    lastLog: string
    worktree: string
    tmuxSession: string
    exitCode: string
    logs: string
    rawLogs: string
    stderr: string
    gitSummary: string
}

export declare class CjTaskCardState {
    title: string
    taskId: string
    status: string
    repo: string
    branch: string
    live: boolean
    createdAt: string
    updatedAt: string
    lastLog: string
}

export declare class CjConnectionState {
    name: string
    host: string
    port: string
    username: string
    password: string
    defaultRepoPath: string
}

export declare interface CustomLib {
    CjConnectionState: {new (): CjConnectionState}
    CjTaskCardState: {new (): CjTaskCardState}
    CjTaskDetailState: {new (): CjTaskDetailState}
    CjLogPanelState: {new (): CjLogPanelState}
    CjResultBool: {new (): CjResultBool}
    CjResultString: {new (): CjResultString}
    CjResultTaskCard: {new (): CjResultTaskCard}
    CjResultTaskDetail: {new (): CjResultTaskDetail}
    CjResultLogPanel: {new (): CjResultLogPanel}
    cjLoadConnection(): CjConnectionState
    cjSaveConnection(name: string, host: string, port: string, user: string, pass: string, repo: string): CjResultBool
    cjTestConnection(host: string, port: string, user: string, pass: string): Promise<CjResultBool>
    cjInitRemote(host: string, port: string, user: string, pass: string): Promise<CjResultBool>
    cjLoadTasks(host: string, port: string, user: string, pass: string): Promise<CjResultString>
    cjSubmitTask(host: string, port: string, user: string, pass: string, repoPath: string, title: string, prompt: string, modeStr: string): Promise<CjResultTaskCard>
    cjOpenTask(taskId: string): Promise<CjResultTaskDetail>
    cjRefreshTask(host: string, port: string, user: string, pass: string, taskId: string): Promise<CjResultTaskDetail>
    cjRefreshLogs(host: string, port: string, user: string, pass: string, taskId: string): Promise<CjResultLogPanel>
    cjStopTask(host: string, port: string, user: string, pass: string, taskId: string): Promise<CjResultBool>
    cjSoftDeleteTask(host: string, port: string, user: string, pass: string, taskId: string): Promise<CjResultBool>
    cjLoadGitSummary(host: string, port: string, user: string, pass: string, taskId: string): Promise<CjResultString>
}
