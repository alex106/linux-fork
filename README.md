# Fork on Linux, in Docker

[Fork](https://git-fork.com/) is a Windows and macOS Git client. This image runs the official Windows build (2.16.1) under Wine and opens the window on your Linux desktop through X11 / XWayland.

Fork costs $59.99 and includes a free evaluation. The container downloads the installer from Fork's CDN. It does not include a license. Activate the evaluation or your license inside the app; both are stored in the `fork-data` volume.

## Run

```bash
./run.sh
```

`run.sh` uses the host Docker engine (`/var/run/docker.sock`) rather than Docker Desktop. Desktop runs containers in a virtual machine, so the Fork window cannot appear on your desktop.

The image build installs Wine. The first launch then installs .NET Framework 4.7.2 and Fork into a data volume. That first launch usually takes 20–40 minutes. Later launches reuse the volume and open the window directly.

Your home directory is mounted at the same path. In Fork, open a repository with the Windows path, for example `Z:\home\alexandel\MyProjects\some-repo`.

## Notes

- Diff line numbers in the gutter are not drawn. The diff itself still is. Spell check is off. GitHub toast notifications are off. Those crash Wine's WPF implementation.
- Saving a file updates Local Changes. Fork's own timer only checked whether the repo was dirty, so an edit never entered the list; the timer now reloads that list. Wine also reports changes only for the top directory of a watch, and the container forwards nested ones.
- After Fork opens, turn off automatic updates under File → Preferences. An update would replace the compatibility fixes. The image also renames Fork's updater so it does not apply one on its own.
- The Preferences window can render as a black box. Escape closes it; the settings are still saved.
- Create Pull Request opens the compare page in your Linux browser. Wine has no browser of its own.
- Console and Open in Git Bash open `xterm` in the repository folder. Wine cannot show Windows `cmd.exe` or mintty.
- Clones use your Linux GitHub login. Wine cannot read Windows Credential Manager. In a terminal on the host, run `gh auth login` with the account that can access the repository, then clone again. For an organization that uses single sign-on, authorize that login for the organization.
- Git name and email come from your Linux `~/.gitconfig`. SSH keys come from `~/.ssh`.
- To start over, including the license activation: `docker compose down -v`
