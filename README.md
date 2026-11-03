# Windows User Profile Rename Tool

<p align="center">
  **PowerShell Automation for Windows User Profile Management**
</p>

A PowerShell tool designed to automate the renaming of Windows user accounts and profile directories in enterprise environments, while preserving existing profile data and configurations.

Developed by **Abdeldjalil Djillali**.

---

## Overview

Managing Windows user profile names across multiple computers can be time-consuming, especially in enterprise environments.

This project provides an automated solution to rename Windows user profiles using a CSV configuration file.

The script identifies existing profiles, validates their configuration, handles active user sessions, backs up registry information, renames profile directories, and updates the corresponding Windows registry entries.

It supports local Windows accounts, Active Directory domain profiles, and profile folders without registered accounts.

## Features

- **Bulk User Renaming:** Rename multiple profiles using a CSV file.
- **Local Account Management:** Rename local Windows accounts and their associated profile directories.
- **Active Directory Support:** Rename domain user profile folders and registry references.
- **Profile Detection:** Identify profiles using `Win32_UserProfile` and Windows ProfileList registry entries.
- **Dry-Run Mode:** Preview planned operations before making changes.
- **Session Management:** Notify users and sign out active sessions before profile modifications.
- **Registry Backup:** Back up registry information before applying changes.
- **Automatic Recovery:** Attempt to restore profile configuration when an operation fails.
- **Logging System:** Generate detailed execution logs.
- **Retry Mechanism:** Retry certain file operations after temporary failures.
- **Safety Checks:** Validate profile paths, SIDs, usernames, and destination conflicts.
- **Enterprise Deployment:** Suitable for deployment through ManageEngine Endpoint Central.

## Requirements

- Windows 10 / Windows 11 / Windows Server.
- Windows PowerShell 5.1.
- Administrator privileges.
- LocalAccounts PowerShell module/cmdlets.
- CSV configuration file.

## Repository Structure

```text
Windows-User-Profile-Rename-Tool/
│
├── Rename-UserProfiles-Final.ps1
├── rename-users-example.csv
├── README.md
└── LICENSE
```

## Configuration

Create a CSV file named `rename-users-example.csv`.

Example:

```csv
OldName,NewName
user1,Employee1
user2,Employee2
Abdeldjalil,A.djil
```

| Column | Description |
|---|---|
| OldName | Existing profile/account name |
| NewName | New profile/account name |

The script supports comma-separated and semicolon-separated CSV files.

## Usage

### 1. Run a Dry Run

The script runs in simulation mode by default.

```powershell
.\Rename-UserProfiles-Final.ps1
```

This checks the profiles and displays the planned changes without modifying the system.

### 2. Apply Changes

```powershell
.\Rename-UserProfiles-Final.ps1 -Apply
```

### 3. Apply Without Confirmation

```powershell
.\Rename-UserProfiles-Final.ps1 -Apply -Force
```

### 4. Set User Warning Time

```powershell
.\Rename-UserProfiles-Final.ps1 -Apply -Force -WarningSeconds 60
```

### 5. Skip Missing Users

```powershell
.\Rename-UserProfiles-Final.ps1 -Apply -SkipMissing
```

### 6. Stop on First Error

```powershell
.\Rename-UserProfiles-Final.ps1 -Apply -StopOnError
```

## Available Parameters

| Parameter | Description |
|---|---|
| `-Apply` | Execute profile renaming operations |
| `-WhatIfMode` | Force simulation mode |
| `-Force` | Skip interactive confirmation |
| `-SkipMissing` | Ignore users not found |
| `-StopOnError` | Stop after the first failed operation |
| `-WarningSeconds` | User notification period |
| `-RenameRetries` | Number of rename retries |
| `-CsvPath` | CSV configuration file path |
| `-LogPath` | Execution log path |
| `-Pause` | Wait for Enter before closing |

## How It Works

The script follows these main stages:

1. Read and validate the CSV configuration.
2. Scan the `C:\Users` directory.
3. Retrieve registered Windows profiles.
4. Identify profile SIDs and registry entries.
5. Build a migration plan.
6. Display the plan in Dry-Run mode.
7. Back up the ProfileList registry.
8. Notify users and sign out active sessions when necessary.
9. Rename the profile directory.
10. Rename the local account when applicable.
11. Update the registry `ProfileImagePath`.
12. Verify the changes.
13. Generate an execution summary.

## Active Directory Compatibility

For domain users, the script updates:

- The local profile directory.
- The corresponding ProfileList registry entry.

**Important:** The script does not rename user accounts directly in Active Directory. Domain account renaming must be performed separately by an authorized AD administrator.

## Backup and Logs

The default backup directory is:

```text
C:\Admin\ProfileRenameBackup
```

The script generates:

- ProfileList registry backup.
- Individual profile registry backups.
- Timestamped execution logs.
- Success, failure, and recovery information.

## Enterprise Deployment

The script can be executed manually or deployed through endpoint management solutions such as:

- ManageEngine Endpoint Central.
- Windows PowerShell administration.
- Enterprise IT automation environments.

For centralized deployment, configure the CSV and log paths according to your environment.

## Important Considerations

- Always execute a Dry Run before applying changes.
- Back up important user data before migration.
- Notify users before signing out active sessions.
- Test on a non-production computer first.
- Ensure the destination profile directory does not already exist.
- Review execution logs after migration.
- Restart the computer and test the renamed account.

**Disclaimer:** This script modifies Windows user profile directories, local accounts, and registry settings. Use it carefully and test it in a controlled environment before production deployment.

## Author

**Abdeldjalil Djillali**

IT Support | Windows Administration | PowerShell Automation | Active Directory | Endpoint Management

---

⭐ If you find this project useful, consider giving the repository a star

