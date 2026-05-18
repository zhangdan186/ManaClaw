package ohos_app_cangjie_entry

internal import ohos.base.CStringExtend

foreign func cc_ssh_connect(host: CString, port: Int32, user: CString, password: CString, timeoutMs: Int32): Int32

foreign func cc_ssh_exec(command: CString, timeoutMs: Int32): Int32

foreign func cc_ssh_exec_once(host: CString, port: Int32, user: CString, password: CString, command: CString, connectTimeoutMs: Int32, execTimeoutMs: Int32): Int32

foreign func cc_ssh_release_result(): Int32

foreign func cc_ssh_disconnect(): Int32

foreign func cc_ssh_stdout(): CString

foreign func cc_ssh_stderr(): CString

foreign func cc_ssh_last_error(): CString

class ExecResult {
    let code: Int32
    let stdout: String
    let stderr: String

    public init(code: Int32, stdout: String, stderr: String) {
        this.code = code
        this.stdout = stdout
        this.stderr = stderr
    }
}

class SshClient {
    public func execCommand(host: String, port: Int32, user: String, password: String, command: String, timeoutMs: Int32): ExecResult {
        unsafe {
            let cHost = LibC.mallocCString(host)
            let cUser = LibC.mallocCString(user)
            let cPassword = LibC.mallocCString(password)
            let cCommand = LibC.mallocCString(command)

            try {
                let code = cc_ssh_exec_once(cHost, port, cUser, cPassword, cCommand, 3000, timeoutMs)
                cHost.free()
                cUser.free()
                cPassword.free()
                cCommand.free()

                let out = cc_ssh_stdout().toString()
                let err = cc_ssh_stderr().toString()
                let finalErr = if (code < 0 && err.size == 0) {
                    cc_ssh_last_error().toString()
                } else {
                    err
                }
                return ExecResult(code, out, finalErr)
            } finally {
                cc_ssh_release_result()
            }
        }
    }

    public func execEchoOk(host: String, port: Int32, user: String, password: String): ExecResult {
        return execCommand(host, port, user, password, "echo ok", 3000)
    }
}
