# Statespace action

This action records the image of the current commit for
[Statespace](https://statespace.com). It runs `ssp apply`:

- On the default branch, the image becomes a default build. Arms based on its
  commit start once a proxy runs it.
- On a branch named `exp/<name>` or `exp/<experiment>/<arm>`, the image becomes
  a version of the arm. The arm runs while GitHub says that the branch's pull request can merge.
- On other branches, nothing is recorded.

The action proves the repository, workflow, and commit with the job's GitHub
OIDC token. The job needs `id-token: write`. It keeps no Statespace secret.

## Use

On [statespace.com](https://statespace.com), select **Connect GitHub**, and
install the Statespace GitHub App on the repository. The App opens a "Set up
Statespace" pull request that adds this workflow:

```yaml
on:
  push:
    branches: ["exp/**"]
permissions:
  contents: read
  packages: write
  id-token: write
jobs:
  arm:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        id: build
        with:
          context: .
          push: true
          tags: ghcr.io/acme/web:${{ github.sha }}
      - uses: statespace-tech/action@v1
        with:
          image: ghcr.io/acme/web@${{ steps.build.outputs.digest }}
```

Add the same last step to the workflow that builds production. To build images
another way, such as with ko, Jib, or buildpacks, replace the build step and give
the image to this action.

## Inputs

| Input | Meaning |
| --- | --- |
| `image` | The image of this commit, by tag or digest. Required |
| `file` | The path of `statespace.toml`. The default is `statespace.toml` |
| `dry-run` | `true` checks and prints the plan, but records nothing |

## Outputs

| Output | Meaning |
| --- | --- |
| `plan` | What Statespace does with the image |

## License

Apache-2.0
