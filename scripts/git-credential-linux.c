#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

/* Console helper so Fork's Git can ask the Linux `gh` login.
   Git Credential Manager calls CredEnumerate, which Wine rejects
   with ERROR_INVALID_FLAGS (0x3ec). This program keeps stdin/stdout
   for Git and asks a Linux script to answer. */

static int run_wait(char *cmdline)
{
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    if (!CreateProcessA(NULL, cmdline, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi))
        return 1;
    WaitForSingleObject(pi.hProcess, INFINITE);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 0;
}

int main(int argc, char **argv)
{
    const char *action = (argc > 1 && argv[1][0]) ? argv[1] : "get";
    char inunix[128], outunix[128], indos[160], outdos[160], cmd[640];
    DWORD pid = GetCurrentProcessId();
    DWORD tick = GetTickCount();

    snprintf(inunix, sizeof(inunix), "/tmp/fork-cred-%lu-%lu.in",
             (unsigned long)pid, (unsigned long)tick);
    snprintf(outunix, sizeof(outunix), "/tmp/fork-cred-%lu-%lu.out",
             (unsigned long)pid, (unsigned long)tick);
    snprintf(indos, sizeof(indos), "Z:%s", inunix);
    snprintf(outdos, sizeof(outdos), "Z:%s", outunix);

    FILE *in = fopen(indos, "wb");
    if (!in)
        return 1;
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), stdin)) > 0)
        fwrite(buf, 1, n, in);
    fclose(in);

    snprintf(cmd, sizeof(cmd),
             "C:\\windows\\system32\\start.exe /wait /unix /opt/fork/git-credential-host.sh %s %s %s",
             action, inunix, outunix);
    run_wait(cmd);

    FILE *out = fopen(outdos, "rb");
    if (out) {
        while ((n = fread(buf, 1, sizeof(buf), out)) > 0)
            fwrite(buf, 1, n, stdout);
        fclose(out);
    }
    DeleteFileA(indos);
    DeleteFileA(outdos);
    return 0;
}
