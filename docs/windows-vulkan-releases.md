# Windows Vulkan release builds

The release repository and the source repository are intentionally separate:

- `strix-halo-llamacpp` contains the release notes, tags, and GitHub Actions workflow.
- [`Nathanw1014/llama.cpp`](https://github.com/Nathanw1014/llama.cpp/tree/strix-halo-vulkan) contains the llama.cpp source being compiled.

You do not need to fork `Nathanw1014/llama.cpp` unless you plan to maintain your own source changes. The **Windows Vulkan release** workflow checks out that public repository, builds it, and publishes the ZIP in this repository.

## Building v0.6.6

Run **Actions → Windows Vulkan release → Run workflow** with:

```text
llama_ref: 7b6c61330edf370659f531932e0b91aca67ba055
release_tag: v0.6.6
prerelease: false
```

The commit is the exact source used for the upstream [`v0.6.6` payload](https://github.com/Nathanw1014/strix-halo-llamacpp/releases/tag/v0.6.6). Prefer the full commit SHA over the `strix-halo-vulkan` branch name so a later branch update cannot change a reproducible release build.

## Future releases

Find the payload source commit in the upstream release notes, then use that full SHA as `llama_ref`. Use the upstream version as `release_tag` when you want matching version numbers.

GitHub's automatic **Source code** archives contain this packaging repository because the release tag belongs here. The downloadable Windows ZIP is built from the separate llama.cpp source, and its `BUILD_INFO.txt` records the requested ref and exact commit.

The upstream portable archive may bundle Linux Mesa RADV `.so` files. Those do not belong in the Windows ZIP; Windows uses the installed AMD Vulkan driver instead.
