# slm - Lightweight SSH Login Manager

## Introduction
`slm` (SSH Login Manager) is a **concise, elegant, UNIX-philosophy-compliant** remote host management script, designed specifically for managing SSH login information of remote hosts and enabling passwordless login.

Most similar scripts on the market are often redundant and complex (over 300 lines of code) with poor readability. Therefore, this script was rebuilt with AI assistance, implementing core functionalities entirely relying on native Linux commands to maintain ultimate simplicity and high reliability. It can be used directly as a native system command.

## Core Features
- 🔹 **CRUD Operations**: Add, delete, edit, and list SSH login information of remote hosts
- 🔹 **Quick Login**: One-click login to remote servers via host ID or IP
- 🔹 **Passwordless Configuration**: One-click push of local SSH public key to remote hosts for passwordless login

## Installation
1. Rename the script file `slm.sh` to `slm`
2. Move to the system command directory: `sudo mv slm /usr/local/bin/`
3. Add execution permission: `sudo chmod +x /usr/local/bin/slm`
4. Type `slm` directly in the terminal to use

## Usage
### Command Overview
```bash
slm [command] [arguments]
```

![slm screen shots](https://github.com/user-attachments/assets/4cdb12e3-827e-494f-a096-869d079f3bb2)


### Specific Commands
| Command      | Description                                  | Usage Example                                  |
|--------------|----------------------------------------------|-----------------------------------------------|
| add          | Add a remote host                            | `slm add 192.168.1.100 root 22 Example-Server` |
| del          | Delete a remote host (supports ID/IP)        | `slm del 1` or `slm del 192.168.1.100`        |
| edit         | Edit host information (supports ID/IP)        | `slm edit 1 192.168.1.101 admin 22 Test-Machine` |
| list         | List all configured hosts                    | `slm list`                                    |
| login        | Login to a remote host (supports ID/IP)      | `slm login 1` or `slm login 192.168.1.100`    |
| push-key     | Push SSH public key (enable passwordless login) | `slm push-key 1`                            |
| help         | Show help information                        | `slm help`                                    |

### Notes
- Ensure an SSH key pair is generated locally before pushing the public key: `ssh-keygen` (press Enter to use default settings)
- Host configuration is stored in `~/.slm/remotes.txt` with default permissions 700/600 for security

## Design Philosophy
- 🍃 Minimal Dependencies: Only uses native Linux commands (ssh, ssh-copy-id, awk, grep, etc.), no additional installations required
- 🔧 Native Experience: After placing in `/usr/local/bin`, it can be called globally like a system command
- 🛡️ Reliable & Secure: Uses atomic updates for file operations, with strictly restricted configuration file permissions to prevent information leakage
