#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

/* GUI helper Fork can Process.Start. Wine cannot show mintty/cmd.

   Installed as:
   - fork-linux-terminal.exe (Console / custom shell)
   - git-bash.exe (Open in Git Bash)
   - bash.exe next to PortableGit, with the real MSYS bash saved as
     bash-msys.exe. A command line means a Git hook; otherwise open xterm.
*/

static void basename_of(const char *path, char *out, size_t n)
{
    const char *s = path;
    for (const char *p = path; *p; p++) {
        if (*p == '\\' || *p == '/')
            s = p + 1;
    }
    strncpy(out, s, n - 1);
    out[n - 1] = 0;
}

static void dir_of(const char *path, char *out, size_t n)
{
    strncpy(out, path, n - 1);
    out[n - 1] = 0;
    char *last = NULL;
    for (char *p = out; *p; p++) {
        if (*p == '\\' || *p == '/')
            last = p;
    }
    if (last)
        *last = 0;
    else
        strncpy(out, ".", n);
}

static void to_unix(const char *win, char *unixp, size_t n)
{
    if ((win[0] == 'Z' || win[0] == 'z') && win[1] == ':') {
        size_t j = 0;
        for (size_t i = 2; win[i] && j + 1 < n; i++)
            unixp[j++] = (win[i] == '\\') ? '/' : win[i];
        unixp[j] = 0;
        if (unixp[0] == 0) {
            unixp[0] = '/';
            unixp[1] = 0;
        }
    } else {
        strncpy(unixp, "/tmp", n);
        unixp[n - 1] = 0;
    }
}

static int run(char *cmdline, int wait)
{
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    if (!CreateProcessA(NULL, cmdline, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi))
        return 1;
    int code = 0;
    if (wait) {
        DWORD ec = 0;
        WaitForSingleObject(pi.hProcess, INFINITE);
        GetExitCodeProcess(pi.hProcess, &ec);
        code = (int)ec;
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return code;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR args, int show)
{
    char self[MAX_PATH], base[MAX_PATH], dir[MAX_PATH];
    (void)inst;
    (void)prev;
    (void)show;

    GetModuleFileNameA(NULL, self, MAX_PATH);
    basename_of(self, base, sizeof(base));
    dir_of(self, dir, sizeof(dir));

    if (args && args[0] && _stricmp(base, "bash.exe") == 0) {
        char cmd[4096];
        snprintf(cmd, sizeof(cmd), "\"%s\\bash-msys.exe\" %s", dir, args);
        return run(cmd, 1);
    }

    char cwd[MAX_PATH], unixp[MAX_PATH * 2], cmd[2048];
    if (!GetCurrentDirectoryA(sizeof(cwd), cwd))
        lstrcpynA(cwd, "Z:\\tmp", sizeof(cwd));
    to_unix(cwd, unixp, sizeof(unixp));
    snprintf(cmd, sizeof(cmd),
             "C:\\windows\\system32\\start.exe /unix /opt/fork/open-linux-terminal.sh \"%s\"",
             unixp);
    return run(cmd, 0);
}
