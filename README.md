# Statespace action

This action records the image or the files of the current commit as a build
for [Statespace](https://statespace.com). A build is a record "commit → image
digest" or "commit → files location and hash". When a commit has a build, a
person or an agent can make the commit an arm of an experiment:

```shell
ssp experiment update checkout --app shop-prod \
  --arm c0ffee1=0.05 --arm a1b2c3d=0.05
```

The action:

1. Reads `statespace.toml` from the folder `path`.
2. Gets a GitHub OIDC token for the job. The token proves the repository and
   the commit. CI keeps no Statespace secret.
3. For an image by digest, checks that the registry has the image. For
   files, downloads the files and calculates their hash.
4. Sends the image or the files, the folder, the app (when you give it), and
   the text of `statespace.toml` to Statespace.
5. Prints the build that Statespace recorded, and each warning.

Statespace checks `statespace.toml`. When the file has an error, the step
fails with the message from Statespace.

The action records builds of all branches. A branch name has no meaning to
Statespace.

## Use

Before you use the action, do these steps:

1. On [statespace.com](https://statespace.com), install the Statespace GitHub
   App on the repository.
2. In the folder of the app's code, write `statespace.toml`. Start from the
   starter file in the docs:
   <https://docs.statespace.com/reference/statespace-toml#starter-file>.
   A coding agent can write it.

Then add the action after the step that builds and pushes the image. The job
needs the permission `id-token: write`.

```yaml
on:
  push:
permissions:
  contents: read
  packages: write
  id-token: write
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
      - uses: docker/login-action@c94ce9fb468520275223c153574b00df6fe4bcc9 # v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7
        id: build
        with:
          context: shop
          push: true
          tags: ghcr.io/acme/shop:${{ github.sha }}
      - uses: statespace-tech/action@v1
        with:
          image: ghcr.io/acme/shop@${{ steps.build.outputs.digest }}
          path: shop
```

Build each commit that can become an arm. Also add the action to the workflow
that builds the image that live runs. Statespace finds the live commit from
the build of the live image.

You can build images another way, such as with ko, Jib, or buildpacks. Replace
the build step, and give the image to this action.

## Files builds

A site of static files has no image. For this site, use `files` and not
`image`. Upload the files of each commit to a folder in Amazon S3 or in Google
Cloud Storage. Use a different folder for each commit. Then give that folder to
the action.

For Amazon S3:

```yaml
- run: aws s3 sync dist/ s3://acme-site/builds/${{ github.sha }}/
- uses: statespace-tech/action@v1
  with:
    files: s3://acme-site/builds/${{ github.sha }}/
```

For Google Cloud Storage:

```yaml
- run: gcloud storage rsync -r dist/ gs://acme-site/builds/${{ github.sha }}/
- uses: statespace-tech/action@v1
  with:
    files: gs://acme-site/builds/${{ github.sha }}/
```

The value of `files` must end with `/`. The folder must not be the root of the
bucket.

The action downloads all files in the folder. It calculates one hash of all
the files, and sends the folder and the hash to Statespace. Then Statespace
can find when a file in the folder changes.

The job must have read access to the folder. The job that uploads the files
usually has this access. When the folder has no files, or the action cannot
read it, the step fails.

Do not change the files in the folder after this step. When a file changes,
the hash is different, and Statespace does not use the build.

## Builds for one app

Several apps can run from one folder, such as `shop-dev` and
`shop-prod`. When the image is the same for all of these apps, do not set
`app`. The build is then for all apps of the repository and folder.

When each app has its own image, set `app` on each build:

```yaml
      - uses: statespace-tech/action@v1
        with:
          image: ghcr.io/acme/shop@${{ steps.prod.outputs.digest }}
          path: shop
          app: shop-prod
```

A build with `app` is only for that app. For that app, it has priority over
a build of the same commit without `app`.

## Inputs

| Input | Meaning |
| --- | --- |
| `image` | The image of this commit. Give `image` or `files`. Give it by digest, such as `ghcr.io/acme/web@sha256:<digest>`. When you give a tag, the action uses `docker` to find the digest. |
| `files` | The folder of the files of this commit, such as `s3://acme-site/builds/<commit>/` or `gs://acme-site/builds/<commit>/`. Give `image` or `files`. The value must end with `/`. |
| `path` | The folder of `statespace.toml`, from the root of the repository. The default is `.`. |
| `app` | The app that this build is for. Optional. |
| `api` | The Statespace API. The default is `https://api.statespace.com`. |

## Outputs

| Output | Meaning |
| --- | --- |
| `image` | The image that Statespace recorded, by digest |
| `files` | The folder of the files that Statespace recorded |
| `hash` | The hash of the files that Statespace recorded, such as `sha256:<hex>` |

## License

Apache-2.0
