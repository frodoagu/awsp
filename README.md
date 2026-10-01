# awsp

Selector de perfiles AWS para quienes entran por **Okta + saml2aws** y tienen muchos tiles, cuentas y roles.

```
$ awsp
> prod
  acme-prod-web-admin        ● 7h42m  acme-prod-web     111111111111  tile-a
  acme-prod-data-sysadmin    ○        acme-prod-data    444444444444  tile-a
```

- **Un menú (fzf) con todas tus cuentas y roles**, de todos los tiles. ● = sesión vigente y tiempo que le queda.
- **Login solo si hace falta**: si la sesión venció, corre `saml2aws login` para ese tile y rol; si no, solo cambia `AWS_PROFILE`.
- **Perfiles con nombre, nunca credenciales en variables de entorno**: `awsp` limpia `AWS_ACCESS_KEY_ID` y compañía, y exporta `AWS_PROFILE`.
- **Sesiones lo más largas posible**: si un rol rechaza la duración pedida, entra con 1h, consulta `MaxSessionDuration` con `iam get-role` y lo recuerda.
- **Un solo MFA para varios roles**: con `saml_cache` de saml2aws la aserción SAML se reusa unos minutos.
- **Contextos de kubectl atados al perfil**: `awsp-eks` crea contextos `<perfil>/<cluster>` que siempre usan las credenciales correctas, aunque cambies `AWS_PROFILE`.

## Requisitos

bash, [saml2aws](https://github.com/Versent/saml2aws), AWS CLI v2, [fzf](https://github.com/junegunn/fzf), `script` (util-linux), GNU `date`. Está probado en Linux.

## Instalación

```bash
git clone https://github.com/frodoagu/awsp.git
cd awsp && ./install.sh     # symlinks a ~/.config/awsp y ~/.local/bin, y una línea en ~/.bashrc
```

1. En `~/.saml2aws`, armá **una sección por tile de AWS en Okta**. Hay un ejemplo en [`examples/saml2aws.example`](examples/saml2aws.example).
2. Generá el inventario:
   ```bash
   awsp-sync            # pide password + MFA una vez por tile
   ```
   Esto escribe `~/.config/awsp/profiles.tsv` y un bloque administrado al final de `~/.aws/config`, que no toca tus otros perfiles. Volvé a correrlo cuando te den acceso a cuentas nuevas.

## Uso

| Comando | Qué hace |
|---|---|
| `awsp` | menú con todos los perfiles |
| `awsp <texto>` | perfil exacto, o menú prefiltrado (si hay una sola coincidencia, la elige directo) |
| `awsp arn:aws:iam::123456789012:role/admin` | por ARN; útil para aliases |
| `awsp -l` | lista los perfiles con el estado de su sesión |
| `awsp off` | limpia `AWS_PROFILE` y las credenciales en variables de entorno |
| `awsp-eks [cluster…]` | agrega o actualiza contextos de kubectl para el perfil actual |

Hay autocompletado con Tab para los nombres de perfil.

Ejemplo de aliases:

```bash
alias web-prod='awsp arn:aws:iam::111111111111:role/admin && awsp-eks web-cluster'
```

## Cómo se nombran los perfiles

Salen de `saml2aws list-roles`, como `<alias-de-cuenta>-<rol>` en minúsculas, por ejemplo `acme-prod-web-admin`. Si la cuenta no tiene alias se usa el ID. Cuando el mismo rol aparece en dos tiles, se queda el primero.

## Archivos

| Archivo | Contenido |
|---|---|
| `~/.config/awsp/profiles.tsv` | inventario: perfil, tile, ARN, ID de cuenta, alias |
| `~/.config/awsp/durations.tsv` | perfiles cuyo rol admite menos que la duración por defecto |
| `~/.aws/config` | bloque `# >>> awsp managed` con la región de cada perfil |
| `~/.aws/credentials` | lo escribe saml2aws, como siempre |

Todo se puede redirigir con `AWSP_DIR`, `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE` y `SAML2AWS_CONFIGFILE`. La región por defecto de los perfiles generados se cambia con `AWSP_DEFAULT_REGION`.

## Tests

```bash
./test/run.sh    # usa stubs de saml2aws y aws; no toca Okta, AWS ni tu ~/.aws
```

## Licencia

MIT
