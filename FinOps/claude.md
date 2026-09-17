# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Reconcile Azure resource-group tags against a SharePoint-hosted CSV that is treated as the source of truth. An Azure DevOps pipeline runs a PowerShell task on a Microsoft-hosted agent, using a User-Assigned Managed Identity (UAMI) with a federated service connection, to read the CSV via Microsoft Graph and update tag values on every resource group across every subscription under a target management group.

Status: greenfield — the intent captured here is the design input; there is no source code in this directory yet.

## Managed tag keys

Only these four keys are reconciled from the CSV. Tag keys are stable across the tenant; only values change per row.

- `BusinessUnit`
- `CostObject`
- `GeneralLedgerCode`
- `FinancialDelegate`

## Value normalization

CSV values are never written verbatim. Before compare or write:

1. Strip whitespace from the CSV column value.
2. Uppercase the result.

Compare-and-update runs against the normalized value — a resource group whose current tag already equals the normalized value is a no-op.

## Runtime shape

- **Trigger**: Azure DevOps pipeline, Microsoft-hosted agent, PowerShell task.
- **Auth**: UAMI + workload-identity federated service connection. No secrets in pipeline variables or scripts.
- **CSV fetch**: Microsoft Graph, using a token acquired for the UAMI (do not assume an app-secret code path).
- **Scope**: enumerate all subscriptions under a management group, then all resource groups in each subscription.

## Access the UAMI must hold

- Microsoft Graph permission to read the SharePoint file (e.g. `Sites.Selected` scoped to the site).
- Reader at the target management group — to list subscriptions and read RG tags.
- Tag Contributor (or equivalent) at the management group — to write tag values on any RG under it without broader control.

## Preservation rules

- Any tag write must **merge**, never replace: only the four managed keys may be touched. Tags outside those keys must remain on the resource group. A write that sends the full tag hashtable without preserving existing keys is a bug.
- Resource groups tag whose row is not present in the CSV must not be modified at all.
- Log per resource group: keys inspected, current value vs. normalized CSV value, and whether an update was issued. After write, re-read the RG tags and confirm the normalized value is present.
