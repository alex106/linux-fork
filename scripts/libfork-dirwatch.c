/* Forward nested directory changes into Wine.
 *
 * ReadDirectoryChangesW in Wine 11 only installs an inotify watch on the
 * directory that was opened. A recursive watch is supposed to cover existing
 * subfolders too, but Wine adds those watches only when a folder is created
 * later. Edits under a folder that was already there never reach Fork, so the
 * window keeps showing the old tree.
 *
 * This library is loaded into wineserver. When Wine watches a directory, we
 * watch the subfolders on the same inotify fd and rewrite their events so
 * they look like events on the original watch, with a relative path. Wine
 * already turns '/' into '\' before the Windows program sees the name.
 */
#define _GNU_SOURCE

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/syscall.h>
#include <unistd.h>

#define MAX_DEPTH 256
#define PENDING_SIZE (1 << 20)

struct child {
    int root_wd;
    char *rel;
};

struct root {
    int wd;
    int dfd;
    uint32_t mask;
    char *resolved;
};

static int (*real_inotify_init)(void);
static int (*real_inotify_init1)(int);
static int (*real_inotify_add_watch)(int, const char *, uint32_t);
static int (*real_inotify_rm_watch)(int, int);
static ssize_t (*real_read)(int, void *, size_t);
static int (*real_close)(int);

static int ready;
static int in_init;
static int enabled;
static int debug;
static int warned_limit;
static int inotify_fd = -1;
static int child_count;

static struct child **by_wd;
static size_t by_wd_n;

static struct root *roots;
static size_t root_n;
static size_t root_cap;

static unsigned char pending[PENDING_SIZE];
static size_t pending_len;
static size_t pending_off;

static void ensure_init(void);

static ssize_t raw_read(int fd, void *buf, size_t count)
{
    if (in_init || !real_read)
        return syscall(SYS_read, fd, buf, count);
    return real_read(fd, buf, count);
}

static int raw_close(int fd)
{
    if (in_init || !real_close)
        return syscall(SYS_close, fd);
    return real_close(fd);
}

static void warn_limit(void)
{
    if (warned_limit)
        return;
    warned_limit = 1;
    fprintf(stderr, "fork-dirwatch: inotify watch limit reached; some folders will not refresh\n");
}

static char *join_rel(const char *parent, const char *name)
{
    size_t lp = strlen(parent);
    size_t ln = strlen(name);
    char *path = malloc(lp + ln + 2);

    if (!path)
        return NULL;
    if (lp == 0) {
        memcpy(path, name, ln + 1);
        return path;
    }
    memcpy(path, parent, lp);
    path[lp] = '/';
    memcpy(path + lp + 1, name, ln + 1);
    return path;
}

static char *name_dup(const struct inotify_event *ev)
{
    size_t n = ev->len ? strnlen(ev->name, ev->len) : 0;
    char *name = malloc(n + 1);

    if (!name)
        return NULL;
    memcpy(name, ev->name, n);
    name[n] = '\0';
    return name;
}

static struct child *lookup_child(int wd)
{
    if (wd < 0 || (size_t)wd >= by_wd_n)
        return NULL;
    return by_wd[wd];
}

static struct root *find_root(int wd)
{
    size_t i;

    for (i = 0; i < root_n; i++) {
        if (roots[i].wd == wd)
            return &roots[i];
    }
    return NULL;
}

static void forget_child(int wd)
{
    struct child *child = lookup_child(wd);

    if (!child)
        return;
    free(child->rel);
    free(child);
    by_wd[wd] = NULL;
    child_count--;
}

static int remember_child(int wd, int root_wd, char *rel)
{
    size_t n;
    struct child **grown;
    struct child *child;

    if (wd < 0)
        return 0;
    if ((size_t)wd >= by_wd_n) {
        n = by_wd_n ? by_wd_n : 1024;
        while (n <= (size_t)wd) {
            if (n > (1u << 20))
                return 0;
            n *= 2;
        }
        grown = realloc(by_wd, n * sizeof(*by_wd));
        if (!grown)
            return 0;
        memset(grown + by_wd_n, 0, (n - by_wd_n) * sizeof(*grown));
        by_wd = grown;
        by_wd_n = n;
    }

    if (by_wd[wd])
        forget_child(wd);

    child = calloc(1, sizeof(*child));
    if (!child)
        return 0;
    child->root_wd = root_wd;
    child->rel = rel;
    by_wd[wd] = child;
    child_count++;
    return 1;
}

static int is_git_objects(const struct root *root, const char *parent_rel, const char *name)
{
    size_t n;

    if (strcmp(name, "objects") != 0)
        return 0;
    if (strcmp(parent_rel, ".git") == 0)
        return 1;
    n = strlen(parent_rel);
    if (n >= 5 && memcmp(parent_rel + n - 5, "/.git", 5) == 0)
        return 1;
    if (parent_rel[0] == '\0' && root->resolved) {
        n = strlen(root->resolved);
        if (n >= 4 && strcmp(root->resolved + n - 4, ".git") == 0)
            return 1;
    }
    return 0;
}

static int open_rel(int rootfd, const char *rel)
{
    int fd = dup(rootfd);
    const char *cursor = rel;

    if (fd < 0)
        return -1;
    if (!rel || rel[0] == '\0')
        return fd;

    while (*cursor) {
        const char *slash = strchr(cursor, '/');
        size_t len = slash ? (size_t)(slash - cursor) : strlen(cursor);
        char name[NAME_MAX + 1];
        int next;

        if (len == 0 || len > NAME_MAX) {
            raw_close(fd);
            return -1;
        }
        memcpy(name, cursor, len);
        name[len] = '\0';
        next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        raw_close(fd);
        if (next < 0)
            return -1;
        fd = next;
        cursor = slash ? slash + 1 : cursor + len;
    }
    return fd;
}

static void scan_children(const struct root *root, int parentfd, const char *parent_rel, int depth);

static void watch_tree_at(const struct root *root, int dfd, const char *rel, int depth)
{
    char proc[64];
    int wd;
    char *owned;

    snprintf(proc, sizeof(proc), "/proc/self/fd/%d", dfd);
    wd = real_inotify_add_watch(inotify_fd, proc, root->mask);
    if (wd < 0) {
        if (errno == ENOSPC)
            warn_limit();
        if (debug)
            fprintf(stderr, "fork-dirwatch: watch %s failed: %s\n", rel, strerror(errno));
        return;
    }
    if (lookup_child(wd) || find_root(wd)) {
        if (debug)
            fprintf(stderr, "fork-dirwatch: %s reuses wd %d\n", rel, wd);
        return;
    }

    owned = strdup(rel);
    if (!owned || !remember_child(wd, root->wd, owned)) {
        free(owned);
        return;
    }
    scan_children(root, dfd, owned, depth + 1);
}

static void scan_children(const struct root *root, int parentfd, const char *parent_rel, int depth)
{
    int dupfd;
    DIR *dir;
    struct dirent *ent;

    if (depth > MAX_DEPTH)
        return;
    dupfd = dup(parentfd);
    if (dupfd < 0)
        return;
    dir = fdopendir(dupfd);
    if (!dir) {
        raw_close(dupfd);
        return;
    }

    while ((ent = readdir(dir)) != NULL) {
        int childfd;

        if (ent->d_name[0] == '.' &&
            (ent->d_name[1] == '\0' || (ent->d_name[1] == '.' && ent->d_name[2] == '\0')))
            continue;
        if (is_git_objects(root, parent_rel, ent->d_name))
            continue;

        childfd = openat(dirfd(dir), ent->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (childfd < 0)
            continue;

        char *rel = join_rel(parent_rel, ent->d_name);
        if (!rel) {
            raw_close(childfd);
            continue;
        }
        watch_tree_at(root, childfd, rel, depth);
        free(rel);
        raw_close(childfd);
    }
    closedir(dir);
}

static void watch_created_dir(struct root *root, const char *rel)
{
    int fd;

    if (!rel || rel[0] == '\0' || root->dfd < 0)
        return;
    fd = open_rel(root->dfd, rel);
    if (fd < 0) {
        if (debug && errno != ENOTDIR)
            fprintf(stderr, "fork-dirwatch: cannot open %s: %s\n", rel, strerror(errno));
        return;
    }
    watch_tree_at(root, fd, rel, 0);
    raw_close(fd);
}

static void release_children(int root_wd)
{
    size_t i;

    for (i = 0; i < by_wd_n; i++) {
        if (!by_wd[i] || by_wd[i]->root_wd != root_wd)
            continue;
        if (real_inotify_rm_watch)
            real_inotify_rm_watch(inotify_fd, (int)i);
        forget_child((int)i);
    }
}

static void drop_root(int wd)
{
    size_t i;

    for (i = 0; i < root_n; i++) {
        if (roots[i].wd != wd)
            continue;
        release_children(wd);
        if (roots[i].dfd >= 0)
            raw_close(roots[i].dfd);
        free(roots[i].resolved);
        roots[i] = roots[root_n - 1];
        root_n--;
        return;
    }
}

static size_t event_bytes(const struct inotify_event *ev)
{
    return offsetof(struct inotify_event, name) + ev->len;
}

static void append_raw(const struct inotify_event *ev)
{
    size_t total = event_bytes(ev);

    if (pending_len + total > sizeof(pending))
        return;
    memcpy(pending + pending_len, ev, total);
    pending_len += total;
}

static void append_named(int wd, uint32_t mask, uint32_t cookie, const char *name)
{
    size_t namelen = strlen(name);
    size_t raw = offsetof(struct inotify_event, name) + namelen + 1;
    size_t total = (raw + sizeof(struct inotify_event) - 1) & ~(sizeof(struct inotify_event) - 1);
    size_t len_field = total - offsetof(struct inotify_event, name);
    struct inotify_event *out;

    if (pending_len + total > sizeof(pending))
        return;
    out = (struct inotify_event *)(pending + pending_len);
    memset(out, 0, total);
    out->wd = wd;
    out->mask = mask;
    out->cookie = cookie;
    out->len = (uint32_t)len_field;
    memcpy(out->name, name, namelen);
    pending_len += total;
}

static void translate_event(const struct inotify_event *ev)
{
    struct child *child = lookup_child(ev->wd);
    char *name;
    char *full;

    if (!child) {
        struct root *root = find_root(ev->wd);

        append_raw(ev);
        if (!root || !(ev->mask & IN_CREATE))
            return;
        name = name_dup(ev);
        if (!name || name[0] == '\0') {
            free(name);
            return;
        }
        if (!is_git_objects(root, "", name))
            watch_created_dir(root, name);
        free(name);
        return;
    }

    if ((ev->mask & IN_IGNORED) || ev->len == 0) {
        if (ev->mask & IN_IGNORED)
            forget_child(ev->wd);
        return;
    }

    name = name_dup(ev);
    if (!name || name[0] == '\0') {
        free(name);
        return;
    }
    full = join_rel(child->rel, name);
    if (!full) {
        free(name);
        append_raw(ev);
        return;
    }
    append_named(child->root_wd, ev->mask, ev->cookie, full);
    if (ev->mask & IN_CREATE) {
        struct root *root = find_root(child->root_wd);

        if (root && !is_git_objects(root, child->rel, name))
            watch_created_dir(root, full);
    }
    if (debug)
        fprintf(stderr, "fork-dirwatch: %s\n", full);
    free(full);
    free(name);
}

static void translate_buffer(const char *raw, size_t n)
{
    size_t off = 0;

    while (off + offsetof(struct inotify_event, name) <= n) {
        const struct inotify_event *ev = (const struct inotify_event *)(raw + off);
        size_t total = event_bytes(ev);

        if (off + total > n)
            break;
        translate_event(ev);
        off += total;
    }
}

static ssize_t copy_pending(void *buf, size_t count)
{
    size_t off = pending_off;
    size_t out = 0;

    while (off + offsetof(struct inotify_event, name) <= pending_len) {
        const struct inotify_event *ev = (const struct inotify_event *)(pending + off);
        size_t total = event_bytes(ev);

        if (off + total > pending_len)
            break;
        if (out + total > count)
            break;
        off += total;
        out += total;
    }
    if (out == 0) {
        errno = EINVAL;
        return -1;
    }
    memcpy(buf, pending + pending_off, out);
    pending_off += out;
    if (pending_off >= pending_len) {
        pending_off = 0;
        pending_len = 0;
    }
    return (ssize_t)out;
}

static ssize_t translate_read(int fd, void *buf, size_t count)
{
    char raw[8192];
    ssize_t n;

    if (pending_off < pending_len)
        return copy_pending(buf, count);

    pending_off = 0;
    pending_len = 0;
    n = real_read(fd, raw, sizeof(raw));
    if (n <= 0)
        return n;
    translate_buffer(raw, (size_t)n);
    if (pending_len == 0) {
        errno = EAGAIN;
        return -1;
    }
    return copy_pending(buf, count);
}

static void ensure_init(void)
{
    char comm[32];
    int fd;
    ssize_t n;

    if (ready)
        return;
    if (in_init)
        return;
    in_init = 1;

    real_read = dlsym(RTLD_NEXT, "read");
    real_close = dlsym(RTLD_NEXT, "close");
    real_inotify_init = dlsym(RTLD_NEXT, "inotify_init");
    real_inotify_init1 = dlsym(RTLD_NEXT, "inotify_init1");
    real_inotify_add_watch = dlsym(RTLD_NEXT, "inotify_add_watch");
    real_inotify_rm_watch = dlsym(RTLD_NEXT, "inotify_rm_watch");

    memset(comm, 0, sizeof(comm));
    fd = (int)syscall(SYS_open, "/proc/self/comm", O_RDONLY);
    if (fd >= 0) {
        n = syscall(SYS_read, fd, comm, sizeof(comm) - 1);
        syscall(SYS_close, fd);
        if (n < 0)
            n = 0;
        comm[n] = '\0';
        if (n > 0 && comm[n - 1] == '\n')
            comm[n - 1] = '\0';
    }
    enabled = strncmp(comm, "wineserver", 10) == 0;
    debug = getenv("FORK_DIRWATCH_DEBUG") != NULL;
    if (debug && enabled)
        fprintf(stderr, "fork-dirwatch: active in %s\n", comm);

    in_init = 0;
    ready = 1;
}

int inotify_init(void)
{
    int fd;

    ensure_init();
    if (!real_inotify_init) {
        errno = ENOSYS;
        return -1;
    }
    fd = real_inotify_init();
    if (enabled && fd >= 0)
        inotify_fd = fd;
    return fd;
}

int inotify_init1(int flags)
{
    int fd;

    ensure_init();
    if (!real_inotify_init1) {
        errno = ENOSYS;
        return -1;
    }
    fd = real_inotify_init1(flags);
    if (enabled && fd >= 0)
        inotify_fd = fd;
    return fd;
}

int inotify_add_watch(int fd, const char *pathname, uint32_t mask)
{
    int wd;
    int dfd;
    int before;
    char *resolved;
    struct root *root;

    ensure_init();
    if (!real_inotify_add_watch) {
        errno = ENOSYS;
        return -1;
    }
    wd = real_inotify_add_watch(fd, pathname, mask);
    if (!enabled || fd != inotify_fd || wd < 0 || !pathname)
        return wd;
    if (find_root(wd) || lookup_child(wd))
        return wd;

    dfd = open(pathname, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dfd < 0)
        return wd;

    resolved = realpath(pathname, NULL);
    root = NULL;
    if (root_n == root_cap) {
        size_t ncap = root_cap ? root_cap * 2 : 8;
        struct root *grown = realloc(roots, ncap * sizeof(*roots));
        if (grown) {
            roots = grown;
            root_cap = ncap;
        }
    }
    if (root_n < root_cap) {
        root = &roots[root_n++];
        root->wd = wd;
        root->dfd = dfd;
        root->mask = mask;
        root->resolved = resolved;
    }
    if (!root) {
        raw_close(dfd);
        free(resolved);
        return wd;
    }

    before = child_count;
    scan_children(root, dfd, "", 0);
    if (debug) {
        fprintf(stderr, "fork-dirwatch: %s (%d subfolders)\n",
                resolved ? resolved : pathname, child_count - before);
    }
    return wd;
}

int inotify_rm_watch(int fd, int wd)
{
    ensure_init();
    if (!real_inotify_rm_watch) {
        errno = ENOSYS;
        return -1;
    }
    if (enabled && fd == inotify_fd) {
        if (find_root(wd))
            drop_root(wd);
        else
            forget_child(wd);
    }
    return real_inotify_rm_watch(fd, wd);
}

ssize_t read(int fd, void *buf, size_t count)
{
    ensure_init();
    if (!enabled || fd != inotify_fd || inotify_fd < 0)
        return raw_read(fd, buf, count);
    return translate_read(fd, buf, count);
}

int close(int fd)
{
    ensure_init();
    if (enabled && fd == inotify_fd)
        inotify_fd = -1;
    return raw_close(fd);
}
