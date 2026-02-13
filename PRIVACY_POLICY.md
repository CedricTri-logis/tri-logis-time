# Privacy Policy - GPS Clock-In Tracker

**Last updated:** February 13, 2026
**Company:** Trilogis
**App:** GPS Clock-In Tracker (ca.trilogis.gpstracker)

## Overview

GPS Clock-In Tracker ("the App") is a workforce management application developed by Trilogis. This privacy policy explains how we collect, use, and protect your personal data when you use the App.

## Data We Collect

### 1. Location Data
- **Precise GPS coordinates** are collected when you clock in, clock out, and continuously during active shifts.
- **Background location** is collected while a shift is active, even when the App is minimized or the screen is off. This is required to verify work attendance and generate shift route records.
- Location data is **only collected during active shifts**. No location data is collected when you are not clocked in.

### 2. Personal Information
- Full name and employee ID (provided by your employer)
- Email address (used for authentication)
- Role within your organization (employee, manager, admin)

### 3. Camera Data
- The camera is used **solely** to scan QR codes for cleaning session check-in and check-out.
- No photos or videos are captured, stored, or transmitted. The camera feed is processed in real-time for QR code detection only.

### 4. Device Information
- GPS accuracy metrics
- Device location service status (enabled/disabled)
- Network connectivity status (online/offline)

## How We Use Your Data

| Data | Purpose |
|------|---------|
| GPS location during shifts | Verify work attendance and location; generate shift route records for employer review |
| Background location | Maintain continuous location verification during active shifts |
| Name and employee ID | Identify you within your organization's workforce management system |
| Email | Account authentication and password recovery |
| QR code scans | Record cleaning session check-ins and check-outs at specific rooms/studios |

## Data Storage and Security

- **Cloud storage:** Data is stored securely on Supabase (PostgreSQL) with row-level security policies.
- **Local storage:** Offline data is stored on-device using SQLCipher (AES-256 encrypted SQLite database).
- **Authentication tokens** are stored using platform-secure storage (Android Keystore / iOS Keychain).
- All network communication uses HTTPS/TLS encryption.

## Data Sharing

- Your data is accessible to **your employer's authorized managers and administrators** within the App for workforce management purposes.
- We do **not** sell, rent, or share your personal data with third parties for advertising or marketing purposes.
- We do **not** share location data with any third party outside of your employer's organization.

## Data Retention

- Shift and location data is retained as long as your employment relationship with your employer is active, or as required by applicable labor laws.
- You may request deletion of your data by contacting your employer or Trilogis directly.

## Your Rights

Depending on your jurisdiction, you may have the right to:
- Access the personal data we hold about you
- Request correction of inaccurate data
- Request deletion of your data
- Withdraw consent for data collection
- Receive a copy of your data in a portable format

To exercise any of these rights, contact us at the address below.

## Background Location Disclosure

This App collects location data in the background **only during active work shifts** to enable continuous attendance verification. Background location tracking:
- **Starts** when you clock in to a shift
- **Stops** when you clock out or the shift ends
- Is **never active** outside of work shifts
- Is indicated by a **persistent notification** on your device while active

Without background location access, the App cannot verify your work attendance while the screen is off, which is a core requirement of the workforce management system.

## Children's Privacy

This App is intended for use by employed adults only. We do not knowingly collect data from anyone under the age of 16.

## Changes to This Policy

We may update this privacy policy from time to time. We will notify users of material changes through the App or via email.

## Contact Us

**Trilogis**
Email: cedric@trilogis.ca
Website: https://trilogis.ca

If you have questions or concerns about this privacy policy or your data, please contact us at the email address above.
