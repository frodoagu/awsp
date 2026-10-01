# awsp

AWS profile picker for people who sign in through **Okta + saml2aws** and juggle many tiles, accounts and roles.

```
$ awsp
> prod
  acme-prod-web-admin        ● 7h42m  acme-prod-web     111111111111  tile-a
  acme-prod-data-sysadmin    ○        acme-prod-data    444444444444  tile-a
```

- **One menu (fzf) with all your accounts and roles**, across every tile. ● = active session and how long it has left.
- **Logs in only when needed**: if the session expired it runs `saml2aws login` for that tile and role; otherwise it just switches `AWS_PROFILE`.
- **Named profiles, never credentials in environment variables**: `awsp` clears `AWS_ACCESS_KEY_ID` and friends and exports `AWS_PROFILE`.
- **Sessions as long as allowed**: if a role rejects the requested duration, awsp logs in for 1h, reads `MaxSessionDuration` with `iam get-role`, and remembers it.
- **One MFA for several roles**: with saml2aws' `saml_cache`, the SAML assertion is reused for a few minutes.
- **kubectl contexts bound to a profile**: `awsp-eks` creates `<profile>/<cluster>` contexts that always use the right credentials, even after you switch `AWS_PROFILE`.

## Requirements

bash, [saml2aws](https://github.com/Versent/saml2aws), AWS CLI v2, [fzf](https://github.com/junegunn/fzf), `script` (util-linux), GNU `date`. Tested on Linux.

## Install

```bash
git clone https://github.com/frodoagu/awsp.git
cd awsp && ./install.sh     # symlinks into ~/.config/awsp and ~/.local/bin, plus one line in ~/.bashrc
```

1. In `~/.saml2aws`, add **one section per AWS tile in Okta**. See [`examples/saml2aws.example`](examples/saml2aws.example).
2. Build the inventory:
   ```bash
   awsp-sync            # asks for password + MFA once per tile
   ```
   This writes `~/.config/awsp/profiles.tsv` and a managed block at the end of `~/.aws/config`; your other profiles are left alone. Run it again whenever you get access to new accounts.

## Usage

| Command | What it does |
|---|---|
| `awsp` | menu with every profile |
| `awsp <text>` | exact profile, or a pre-filtered menu (a single match is picked directly) |
| `awsp arn:aws:iam::123456789012:role/admin` | by role ARN; handy for aliases |
| `awsp -l` | list profiles with their session status |
| `awsp off` | clear `AWS_PROFILE` and any credentials in environment variables |
| `awsp-eks [cluster…]` | add or update kubectl contexts for the current profile |

Profile names tab-complete.

Example aliases:

```bash
alias web-prod='awsp arn:aws:iam::111111111111:role/admin && awsp-eks web-cluster'
```

## Profile naming

Names come from `saml2aws list-roles` as `<account-alias>-<role>` in lowercase, e.g. `acme-prod-web-admin`. Accounts without an alias use their ID. When the same role shows up in two tiles, the first one wins.

## Files

| File | Contents |
|---|---|
| `~/.config/awsp/profiles.tsv` | inventory: profile, tile, role ARN, account ID, alias |
| `~/.config/awsp/durations.tsv` | profiles whose role allows less than the default duration |
| `~/.aws/config` | `# >>> awsp managed` block with each profile's region |
| `~/.aws/credentials` | written by saml2aws, as usual |

Everything can be redirected with `AWSP_DIR`, `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE` and `SAML2AWS_CONFIGFILE`. The default region for generated profiles is set with `AWSP_DEFAULT_REGION`.

## Tests

```bash
./test/run.sh    # uses saml2aws and aws stubs; never touches Okta, AWS or your ~/.aws
```

## License

MIT
