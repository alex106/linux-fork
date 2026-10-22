# Fork has no Linux build. This image runs the official Windows installer
# under Wine and shows the window on the host X11/XWayland display.
#
# Fork 2.16.1 is pinned because that is the build the Wine compatibility
# fixes were verified against. Fork is commercial software: the evaluation
# or a purchased license is still required inside the app.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    WINEPREFIX=/opt/wine-fork \
    FORK_VERSION=2.16.1

RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        cabextract \
        curl \
        gnupg \
        locales \
        p7zip-full \
        python3 \
        python3-pip \
        unzip \
        wget \
        xz-utils \
    && sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen \
    && locale-gen en_US.UTF-8 \
    && mkdir -pm755 /etc/apt/keyrings \
    && wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
    && wget -NP /etc/apt/sources.list.d/ \
        https://dl.winehq.org/wine-builds/ubuntu/dists/jammy/winehq-jammy.sources \
    && apt-get update \
    && apt-get install -y --install-recommends winehq-staging \
    && apt-get install -y --no-install-recommends \
        git \
        mingw-w64 \
        winbind \
        xvfb \
    && curl -fsSL https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
        -o /usr/local/bin/winetricks \
    && chmod +x /usr/local/bin/winetricks \
    && pip3 install --no-cache-dir dnfile \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libegl1 \
        libgl1 \
        libgl1-mesa-dri \
        libvulkan1 \
        libxcomposite1 \
        libxcursor1 \
        libxi6 \
        libxrandr2 \
        libxrender1 \
        mesa-vulkan-drivers \
        xterm \
    && rm -rf /var/lib/apt/lists/*

# Ship the Mono and Gecko builds Wine 11.19 asks for. Without them, wineboot
# opens an installer dialog and then crashes while creating the prefix.
RUN mkdir -p /opt/wine-staging/share/wine/mono /opt/wine-staging/share/wine/gecko \
    && curl -fL --retry 3 -o /tmp/wine-mono.tar.xz \
        https://dl.winehq.org/wine/wine-mono/11.3.0/wine-mono-11.3.0-x86.tar.xz \
    && tar -xJf /tmp/wine-mono.tar.xz -C /opt/wine-staging/share/wine/mono \
    && curl -fL --retry 3 -o /tmp/wine-gecko64.tar.xz \
        https://dl.winehq.org/wine/wine-gecko/2.47.4/wine-gecko-2.47.4-x86_64.tar.xz \
    && curl -fL --retry 3 -o /tmp/wine-gecko32.tar.xz \
        https://dl.winehq.org/wine/wine-gecko/2.47.4/wine-gecko-2.47.4-x86.tar.xz \
    && tar -xJf /tmp/wine-gecko64.tar.xz -C /opt/wine-staging/share/wine/gecko \
    && tar -xJf /tmp/wine-gecko32.tar.xz -C /opt/wine-staging/share/wine/gecko \
    && rm -f /tmp/wine-mono.tar.xz /tmp/wine-gecko64.tar.xz /tmp/wine-gecko32.tar.xz

RUN groupadd --gid 1000 fork \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash fork \
    && mkdir -p /opt/wine-fork /data \
    && chown fork:fork /opt/wine-fork /data

# GitHub CLI answers Fork's clone/fetch. Wine cannot use Git Credential Manager.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Wine reports directory changes only for the folder it was asked to watch.
# Fork then misses edits inside existing subfolders. The hook loads a helper
# into wineserver that forwards those nested edits. This layer stays cached
# when only the Fork patch script changes.
COPY scripts/libfork-dirwatch.c scripts/wineserver-hook.sh /opt/fork/
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc libc6-dev \
    && gcc -shared -fPIC -O2 -o /opt/fork/libfork-dirwatch.so \
        /opt/fork/libfork-dirwatch.c -ldl \
    && mv /opt/wine-staging/bin/wineserver /opt/wine-staging/bin/wineserver.real \
    && cp /opt/fork/wineserver-hook.sh /opt/wine-staging/bin/wineserver \
    && chmod 755 /opt/wine-staging/bin/wineserver /opt/fork/libfork-dirwatch.so \
        /opt/fork/wineserver-hook.sh \
    && apt-get purge -y gcc libc6-dev \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/install-fork.sh scripts/patch_fork.py scripts/entrypoint.sh \
     scripts/open-linux-terminal.sh scripts/fork-linux-terminal.cmd \
     scripts/fork-linux-terminal.c scripts/git-credential-linux.c \
     scripts/git-credential-host.sh scripts/install-desktop-shortcut.sh \
     scripts/extract-fork-icon.py scripts/open-host-browser.sh /opt/fork/
RUN x86_64-w64-mingw32-gcc -O2 -mwindows -o /opt/fork/fork-linux-terminal.exe \
        /opt/fork/fork-linux-terminal.c \
    && x86_64-w64-mingw32-gcc -O2 -o /opt/fork/git-credential-linux.exe \
        /opt/fork/git-credential-linux.c \
    && chmod 755 /opt/fork/install-fork.sh /opt/fork/entrypoint.sh /opt/fork/patch_fork.py \
        /opt/fork/open-linux-terminal.sh /opt/fork/git-credential-host.sh \
        /opt/fork/install-desktop-shortcut.sh /opt/fork/extract-fork-icon.py \
        /opt/fork/open-host-browser.sh \
    && chmod 644 /opt/fork/fork-linux-terminal.cmd \
    && chown -R fork:fork /opt/fork

USER fork
ENV HOME=/home/fork \
    USER=fork

USER root
ENTRYPOINT ["/opt/fork/entrypoint.sh"]
