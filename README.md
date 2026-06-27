# SONiC Dev Lab

My personal SONiC virtual switch development environment.

## What is this?
- Run SONiC-VS (Virtual Switch) in Docker
- Modify SONiC components and test changes
- Track all changes in Git

## Quick Start (any machine)
```bash
git clone git@github.com:YOUR_USERNAME/sonic-dev-lab.git
cd sonic-dev-lab
chmod +x scripts/setup.sh
./scripts/setup.sh
```

## Goals
- [x] Run SONiC-VS
- [ ] Add logs to vlanmgr
- [ ] Test STP
- [ ] Implement STP without syncd
