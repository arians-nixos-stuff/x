# Vendored code

Upstream projects are vendored with their full history using
[josh](https://josh-project.github.io/josh/). `josh` and `josh-filter` are in
the dev shell (`nix develop`).

Each upstream has a mapping, `third-party/<name>.josh`: a josh filter that
takes upstream's tree to where it lives in this repository. Usually that is
`:prefix=third-party/<name>`, but a mapping may also spread upstream across the
tree; `buck2.josh` puts buck2's shim at our root, which plays the role of
Meta's fbsource. A mapping may also take only some files of upstream:
`googleapis.josh` takes the few protos we import from a repository of
thousands. Its history then holds just the upstream commits that touch those
files.

Upstream is a josh remote with the mapping as its filter. josh fetches upstream
and rewrites its history through the mapping; the result shows up in jj as
`main@<name>`. Because the mapping is reversible, `josh push` can take commits
in our layout back to upstream's layout, with upstream's real history as their
ancestors.

## Rules

- Mappings only select and move paths. No `:exclude`, `:replace`, `:unsign` or
  squashing: those are lossy and break the way back to upstream.
- A mapping that selects files starts with the selection, in upstream's layout,
  and then moves it:
  `:[ ::google/rpc/status.proto ... ]:prefix=third-party/googleapis`.
  Select whole files or directories, one `::` entry per line. Leaving
  everything else out is not lossy: `josh push` applies our changes to
  upstream's own tree, so the files we left out come through unchanged.
- When a mapping moves upstream paths into directories we share (such as
  `third-party/` or `tools/` at the root), list the moved entries one by one.
  Otherwise the inverse claims our own files as upstream's.
- Changing a mapping changes every mapped commit hash, so it means importing
  again.
- Local changes to vendored code are ordinary changes on top of the import.

CI (`.github/workflows/third-party.yml`) checks every mapping: the inverse of
the mapped upstream branch must reproduce upstream exactly, and the upstream
side of the latest import must be in the mapped upstream history, which proves
the import was made with the mapping as committed. For a mapping that selects
files, "upstream" means upstream with only those files, filtered with the
mapping's `::` entries. CI finds the latest import by the subject of its merge
commit, `third-party/<name>: import upstream ...`. A new vendored project gets
an entry in the workflow's matrix, with `selects: true` if its mapping selects
files.

## Setting up a clone

Once per clone, for each vendored project:

```sh
cd "$(jj workspace root --name default)"
josh remote add buck2 https://github.com/facebook/buck2 "$(cat third-party/buck2.josh)" \
  --push-url git@github.com:<you>/buck2.git
josh fetch -r buck2
```

This stores the remote in `.git/josh/remotes/buck2.josh` and adds a git remote
`buck2` that serves only the mapped refs, so `jj git fetch --remote buck2` can
never bring in unmapped history. `--push-url` is your fork, where `josh push`
sends branches; without it, pushes go to upstream itself.

That git remote does not reach upstream. It points back at this repository,
where josh keeps the mapped refs in the `josh-buck2` namespace, so fetching it
only picks up what the last `josh fetch` mapped. Always update with
`josh fetch`.

`josh remote add` records the directory it runs in as that remote's URL. All
workspaces share the remote, so run it in the default workspace: in a workspace
backed by a git worktree it would record the worktree, and fetching would break
everywhere once that worktree is removed. If that happened, point the remote
back at the default workspace:

```sh
git remote set-url buck2 "file://$(jj workspace root --name default)"
```

josh plans to replace this setup with stores and filtered worktrees
(`rfcs/worktree.md` in the josh repository), so expect these instructions to
change when we move past josh r26.08.28.

To change a remote's settings, `git remote remove buck2`, delete
`.git/josh/remotes/buck2.josh` and add it again.

## Updating

```sh
josh fetch -r buck2
jj new 'trunk()' main@buck2 -m "third-party/buck2: import upstream <short sha>"
```

The import is a merge of trunk and the mapped upstream commit; keep the message
prefix, CI looks for it. jj treats `main@buck2` as an untracked remote
bookmark, so the imported history is immutable and hidden from the default
`jj log`.

Resolve conflicts and regenerate anything derived from upstream in the import
change itself, so that every commit on `main` builds. For buck2 that is the
crate targets: upstream changes `third-party/rust/Cargo.toml`, `reindeer.toml`
and `fixups/`, and `BUCK` and `Cargo.lock` next to them are generated here:

```sh
nix develop --command reindeer --third-party-dir third-party/rust buckify
```

CI fails when `third-party/rust` is not up to date with that command.

To see what this repository changes in buck2, project it into upstream's
layout and compare that with the upstream commit it last imported:

```sh
josh-filter --file <(printf ':invert[\n%s\n]\n' "$(grep -v '^ *#' third-party/buck2.josh)") \
  : "$(jj log -r @ -T commit_id --no-graph)" --update refs/josh/local/buck2
git diff --stat refs/josh/remotes/buck2/main...refs/josh/local/buck2
```

## Contributing upstream

Changes to vendored code land here first, as ordinary changes reviewed in this
repository. To send one upstream, duplicate it onto the mapped upstream and push
the copy through josh:

```sh
josh fetch -r buck2
jj duplicate <change> --onto main@buck2
jj bookmark create buck2/my-fix -r <duplicate>
josh push buck2 buck2/my-fix
gh pr create --repo facebook/buck2 --head <you>:buck2/my-fix
```

`josh push` inverts the mapping: the branch on your fork has upstream's
`main` as its parent, and only touches upstream's paths. Our own files in the
change are left out.

The duplicate is the copy that upstream reviews. It is a separate change, so
rewrite it freely during review (`jj squash`, `jj split`, `jj describe`, or
rebase it onto a newer `main@buck2`) and update the pull request with
`josh push -f buck2 buck2/my-fix`. The change in trunk stays as it was
reviewed here.

Upstream's final version comes back with a later import. Projects exported
from a larger monorepo, such as buck2, publish landed pull requests as new
commits, so the import merge meets the same change twice: if upstream took it
as is, the merge is clean; if it changed in review, the merge conflicts in those
lines, and upstream's version is the one to keep. Afterwards, drop the
duplicate (`jj abandon <duplicate>`) and the bookmark.
