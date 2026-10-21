# Example Dataset Link

This project uses local example datasets for validation, smoke testing, and benchmark comparisons, but the dataset files themselves are intentionally excluded from Git.

Current example dataset family used in this workspace:
- `Mip-NeRF 360`

Purpose:
- provide a known reference dataset for installer validation
- provide repeatable benchmark scenes for sparse reconstruction and training checks
- give future teammates a clear source for obtaining the same example content without storing large dataset files in the repository

Original source:
- Project page: `https://jonbarron.info/mipnerf360/`

Notes:
- Keep downloaded dataset archives and extracted dataset folders under the local `datasets\` area, not in Git.
- Use `config\datasets.example.json` as the tracked template for local dataset paths.
