# Contributing to VaultHound

Thank you for your interest in contributing! VaultHound is an open-source project and we welcome all kinds of contributions — bug fixes, new features, documentation improvements, and more.

---

## Getting Started

1. **Fork** the repository on GitHub
2. **Clone** your fork locally:
   ```bash
   git clone https://github.com/<your-username>/VaultHound.git
   cd VaultHound
   ```
3. **Create a branch** for your change:
   ```bash
   git checkout -b feature/my-feature
   # or
   git checkout -b fix/issue-description
   ```

---

## Development Setup

### Master Server

```bash
cd vaulthound-server/source
npm install
node server.js
# Dashboard: http://localhost:4000
```

### Agent

Requires Go 1.21+ and Trivy installed.

```bash
cd vaulthound-agent
go build -o vaulthound-agent .
./vaulthound-agent --master http://localhost:4000 --dir /tmp --log
```

---

## Areas for Contribution

- 🐛 **Bug fixes** — check the [Issues](https://github.com/krishnabagal/VaultHound/issues) tab
- ✨ **New features** — see the Roadmap in README.md
- 📝 **Documentation** — improve the README, add examples, fix typos
- 🧪 **Tests** — add unit tests for master server routes or agent scanner
- 🎨 **Dashboard UI** — improve charts, add new panels, improve mobile layout
- 🌐 **OS support** — test and fix the installers on new Linux distributions

---

## Pull Request Guidelines

- Keep PRs focused — one feature or fix per PR
- Write a clear description of what the PR does and why
- Test your changes before submitting
- Make sure the agent still compiles: `go build ./...`
- Make sure the server still starts: `node server.js`

---

## Code Style

- **JavaScript** (master server): standard Node.js style, no linter enforced
- **Go** (agent): run `gofmt -w .` before committing
- **Shell scripts**: use `shellcheck` if available

---

## Reporting Issues

When reporting a bug, please include:
- OS and version
- VaultHound version (`vaulthound-agent --version`)
- Steps to reproduce
- Error output (from `journalctl -u vaulthound-agent -n 50` or `--log` output)

---

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
