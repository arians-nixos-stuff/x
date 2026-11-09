# Satellite repositories

Some directories of this repository are also repositories of their own. Each
has a josh mapping here that takes the satellite's tree to where it lives in
this repository:

| Satellite | Mapping | Directory | Synced by |
|---|---|---|---|
| [arianvp/nixos-stuff](https://github.com/arianvp/nixos-stuff) | `nixos-stuff.josh` | `homelab/` | `.github/workflows/nixos-stuff.yml` |

The satellite's history was imported with the mapping, so projecting `main`
through the inverse of the mapping continues the satellite's history with the
same commit hashes. Work happens in this repository; the satellite still takes
commits of its own (dependabot for nixos-stuff), and the two are kept in sync
in both directions, the same way rust-lang/rust and its josh subtrees are:

- **Satellite to here.** When the satellite has commits that `main` has not
  imported, CI merges them into `main` on the `homelab-import` branch and opens
  a pull request. Merge it as a merge commit or a fast-forward, never by
  rebasing: rebasing rewrites the imported commits, and the histories stop
  matching.
- **Here to satellite.** When `main` contains everything the satellite has, CI
  pushes the projection of `main` to the satellite's default branch. That is
  always a fast-forward. Each import shows up there as a merge commit.
  Deployments that run from the satellite (nixbot for nixos-stuff) see an
  ordinary push.

Publishing waits while an import is pending, so merge import pull requests
promptly. CI runs on every push to `main` and daily.

## Importing by hand

When the import pull request cannot be created because of a merge conflict,
import from the default workspace and resolve the conflict in jj:

```sh
cd "$(jj workspace root --name default)"
josh remote add nixos-stuff https://github.com/arianvp/nixos-stuff "$(cat satellites/nixos-stuff.josh)"   # once per clone
josh fetch -r nixos-stuff
jj new 'trunk()' master@nixos-stuff -m "homelab: import arianvp/nixos-stuff <short sha>"
```
