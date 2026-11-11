# awsp

AWS profile picker for people who sign in through **Okta + saml2aws** and juggle many tiles, accounts and roles.

```text
$ awsp
> prod
  acme-prod-web-admin        ● 7h42m  acme-prod-web     111111111111  tile-a
  acme-prod-data-sysadmin    ○        acme-prod-data    444444444444  tile-a
```

- **One command**: everything is an `awsp` subcommand (`awsp setup`, `awsp sync`, `awsp eks`…), and `<Tab>` completes subcommands, profiles and tiles.
- **Guided setup**: `awsp setup` asks for your Okta tiles and writes `~/.saml2aws` for you.
- **One menu (fzf) with all your accounts and roles**, across every tile. ● = active session and how long it has left.
- **Logs in only when needed**: if the session expired it runs `saml2aws login` for that tile and role; otherwise it just switches `AWS_PROFILE`.
- **Named profiles, never credentials in environment variables**: `awsp` clears `AWS_ACCESS_KEY_ID` and friends and exports `AWS_PROFILE`.
- **Sessions as long as allowed**: if a role rejects the requested duration, awsp logs in for 1h, reads `MaxSessionDuration` with `iam get-role`, and remembers it.
- **One MFA for several roles**: with saml2aws' `saml_cache`, the SAML assertion is reused for a few minutes.
- **kubectl contexts bound to a profile**: `awsp eks` creates `<profile>/<cluster>` contexts that always use the right credentials, even after you switch `AWS_PROFILE`.

## Quickstart

You need bash 4+, [saml2aws](https://github.com/Versent/saml2aws), AWS CLI v2, [fzf](https://github.com/junegunn/fzf), `script` (util-linux) and GNU `date`. Tested on Linux.

### 1. Install

```bash
git clone https://github.com/frodoagu/awsp.git
cd awsp && ./install.sh
```

The installer warns about any missing dependency and adds one line to `~/.bashrc` that loads `awsp`. It is a shell function, not a script on your `PATH`, because it has to export `AWS_PROFILE` into your current shell.

### 2. Add your Okta tiles

Open a new terminal (so `awsp` is loaded), then:

```bash
awsp setup
```

It asks, for each AWS tile on your Okta dashboard:

```text
Tile URL: https://acme.okta.com/home/amazon_aws/0oaXXXXXXXXXXXXXXXXX/272
Tile name, shown in the awsp menu (e.g. team-a): team-a
Okta username: me@acme.com
MFA (Auto, PUSH, TOTP, SMS…) [Auto]: TOTP
Session length in hours, 1-12 (awsp lowers it per role when needed) [8]:
Region [us-east-1]:
  added [team-a]
Add another tile? [y/N]
Run awsp sync team-a now (asks for password + MFA per tile)? [Y/n]
```

To get the tile URL, right-click the AWS tile on the Okta dashboard and copy the link. Each tile becomes a section in `~/.saml2aws`, with the SAML cache turned on so switching roles doesn't ask for MFA every time. Answers default to those of the previous tile, so adding more is mostly pressing Enter.

When it finishes, `awsp sync` asks for your Okta password and MFA once per tile, lists every role you can assume and prints the resulting profiles. Run `awsp sync` again whenever you get access to new accounts: `awsp` only shows what is in the inventory, and new accounts in Okta don't appear until you sync.

<details>
<summary>Prefer to edit <code>~/.saml2aws</code> by hand?</summary>

Start from [`examples/saml2aws.example`](examples/saml2aws.example): one section per tile, every section except `[default]` is a tile. Then run `awsp sync`.

</details>

### 3. Pick a profile

```bash
awsp            # menu with everything
awsp prod web   # menu pre-filtered by "prod web"; a single match is picked directly
```

The first time you use a tile you'll be asked for the password again so saml2aws can save it in your keyring; after that, only MFA. Check it worked:

```bash
aws sts get-caller-identity
```

### 4. (Optional) kubectl

```bash
awsp eks        # choose clusters of the current account in fzf
kubectl config get-contexts
```

## Usage

| Command | What it does |
| --- | --- |
| `awsp` | menu with every profile |
| `awsp <text>` | exact profile name, or a menu pre-filtered by `<text>` (a single match is picked directly) |
| `awsp arn:aws:iam::123456789012:role/admin` | pick by role ARN; handy for aliases |
| `awsp setup` | add Okta tiles to `~/.saml2aws` interactively, then sync them |
| `awsp sync` | rebuild the inventory from every tile in `~/.saml2aws` |
| `awsp sync <tile>…` | re-sync only those tiles; rows from the other tiles are kept |
| `awsp eks [cluster…]` | add or update kubectl contexts for the current profile; with no arguments, choose from `eks list-clusters` |
| `awsp list` (or `awsp -l`) | list profiles with their session status |
| `awsp off` (or `awsp -`) | clear `AWS_PROFILE` and any credentials in environment variables |
| `awsp help` (or `awsp -h`) | short help |

Subcommand names (`setup`, `sync`, `eks`, `list`, `off`, `help`) take precedence over profile names.

A session counts as active while it has more than 5 minutes left; below that, `awsp` logs in again.

### Tab completion

| You type | `<Tab>` completes |
| --- | --- |
| `awsp <Tab>` | subcommands and profile names |
| `awsp sync <Tab>` | tile names from `~/.saml2aws` |

Completion reads the inventory on every `<Tab>`, so new profiles show up right after `awsp sync`, without opening a new terminal.

### Aliases

```bash
alias web-prod='awsp arn:aws:iam::111111111111:role/admin && awsp eks web-cluster'
```

ARNs are stable, while profile names depend on account aliases, so aliases by ARN survive renames.

### kubectl contexts

`awsp eks` runs `aws eks update-kubeconfig --profile <current profile> --alias <profile>/<cluster>`. The context pins the profile in its `aws eks get-token` call, so `kubectl --context acme-prod-web-admin/web-cluster` keeps working even after you `awsp` to another account. The region comes from `AWS_REGION`, then the profile's region, then `us-east-1`.

## How it works

### Profile naming

`awsp sync` reads `saml2aws list-roles` and names each role `<account-alias>-<role>`, lowercased with anything other than letters and digits turned into `-`. For example, `role/ops/ReadOnly` in account `acme-dev-web` becomes `acme-dev-web-readonly`. Accounts without an alias use their ID (`333333333333-admin`).

If the same name shows up in two tiles:

- same role ARN: the first tile wins;
- different ARN: the tile name is appended (`acme-prod-web-admin-team-b`).

### Logging in

When the selected profile has no active session, `awsp` runs:

```bash
saml2aws login -a <tile> --role <arn> --profile <profile> --force --cache-saml --skip-prompt
```

- **No saved password** for the tile: it retries without `--skip-prompt` so you can type it.
- **Role rejects the duration** (`DurationSeconds` error): it logs in for 1h, asks IAM for the role's `MaxSessionDuration`, and saves it in `durations.tsv` for next time.

The requested duration otherwise comes from `aws_session_duration` in the tile's section of `~/.saml2aws`.

### Files

| File | Contents |
| --- | --- |
| `~/.config/awsp/profiles.tsv` | inventory: profile, tile, role ARN, account ID, alias |
| `~/.config/awsp/durations.tsv` | profiles whose role allows less than the requested duration |
| `~/.saml2aws` | tile definitions; `awsp setup` appends to it and keeps a copy in `~/.saml2aws.bak.awsp` |
| `~/.aws/config` | `# >>> awsp managed` block with each profile's region |
| `~/.aws/config.bak.awsp` | copy of `~/.aws/config` from before the last change by `awsp sync` |
| `~/.aws/credentials` | written by saml2aws, as usual |

`awsp sync` only rewrites its own block in `~/.aws/config`. If a `[profile …]` with the same name already exists outside the block, it is left alone and not duplicated.

### Environment variables

| Variable | Default | Used for |
| --- | --- | --- |
| `AWSP_DIR` | `~/.config/awsp` | inventory and durations |
| `AWSP_DEFAULT_REGION` | `us-east-1` | region written to generated profiles |
| `SAML2AWS_CONFIGFILE` | `~/.saml2aws` | tile definitions |
| `AWS_CONFIG_FILE` | `~/.aws/config` | managed block |
| `AWS_SHARED_CREDENTIALS_FILE` | `~/.aws/credentials` | session expiry |
| `BINDIR` | `~/.local/bin` | where `install.sh` looks for `awsp-setup` / `awsp-sync` links from older versions, to remove them |

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `awsp: no inventory yet` | Run `awsp setup`, or `awsp sync` if `~/.saml2aws` already has your tiles. |
| `awsp: command not found` | Open a new terminal, or `. ~/.config/awsp/awsp.sh`. awsp is bash-only. |
| `awsp-setup` / `awsp-sync` / `awsp-eks`: command not found | They are subcommands now: `awsp setup`, `awsp sync`, `awsp eks`. See [Updating](#updating-and-uninstalling). |
| `list-roles failed for <tile>` | Check that tile's `url` and `username` in `~/.saml2aws`. An empty Enter at the password prompt also fails. |
| `unknown role arn:…` | The role isn't in the inventory; run `awsp sync` again. |
| MFA on every role switch | Set `saml_cache = true` and a `saml_cache_file` per tile, as in the example. |
| A profile is missing, or new Okta accounts don't show up | Run `awsp sync`: the menu only shows the inventory from the last sync. If it's still missing, the tile it belongs to isn't in `~/.saml2aws` (add it with `awsp setup`), or `awsp sync` skipped it because of an error; scroll back through its output. |

## Updating and uninstalling

`install.sh` creates a symlink into the repo, so `git pull` is enough to update.

Coming from a version with separate `awsp-setup`, `awsp-sync` and `awsp-eks` commands? They are `awsp setup`, `awsp sync` and `awsp eks` now. Run `./install.sh` again (it removes the old links in `~/.local/bin`), open a new terminal, and update any aliases that call the old names.

To uninstall, remove `~/.config/awsp/awsp.sh` and the awsp line in `~/.bashrc`. Optionally also remove `~/.config/awsp` and the `# >>> awsp managed` block in `~/.aws/config`.

## Tests

```bash
./test/run.sh    # uses saml2aws and aws stubs; never touches Okta, AWS or your ~/.aws
```

## License

MIT
