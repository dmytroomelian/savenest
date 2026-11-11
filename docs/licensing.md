# Open source and paid features

Savenest keeps its desktop core under MIT and reserves proprietary paid components and hosted services for separate commercial terms. This repository contains the open-source desktop app and shared automation operations. The Pro MCP adapter is developed separately for the official 0.13.0 distribution. Automatic Pro saving and recovery, cross-device merging, and Teams have their own scope and availability.

This page describes the project policy. It does not replace or add conditions to the [MIT license](../LICENSE). Customer use of the official bundled MCP adapter is covered by the separate [Pro MCP component license](pro-mcp-license.md).

## What stays open source

The current Electron app, Swift helper, and shared core remain under MIT. This includes the existing local saving, search, notes, reader, browser integration, and import/export features. These features continue to work without an account or subscription.

MIT permits commercial use and the sale of copies, subject to its notice requirements. You do not need a separate resale agreement for the MIT-licensed code. Existing MIT releases and contributions retain their permissions. Dependencies keep their own licenses, as described in [third-party notices](../THIRD_PARTY_NOTICES.md).

The [MIT license text](https://opensource.org/license/mit) is the source for these permissions.

## Paid components and resale

Proprietary paid components are kept separately from the MIT core. Hosted service access has its own service terms. The resale policy is:

> Reselling Savenest's proprietary paid components or paid service access requires a separate written commercial agreement with the relevant rights holder. This requirement does not apply to code licensed under MIT.

The [Pro MCP component license](pro-mcp-license.md) permits personal use and use in the customer's own work or business on Macs they own or control while their account has valid Pro access. It permits copies of the official app for installation and backup. This permission does not grant resale rights or rights to the private source code. The component license states the applicable permissions and restrictions; hosted services and third-party AI providers have their own terms.

An open-source client can include account screens and integration code for a paid service. Its MIT license does not itself grant an entitlement to that hosted service. The service must verify access on the server; hiding a button in the client does not protect paid access.

## One app with a shared core

- Develop shared app behavior and bug fixes in this public repository. Avoid maintaining a duplicate paid fork.
- Keep hosted implementations in the separate backend. If a new paid feature needs proprietary desktop code, put that code in a private module with an explicit commercial license before distribution.
- Have the paid module use the shared core. The public core must build and run its free features without the private module.
- Keep existing local data readable, editable, and exportable when a subscription ends or a hosted service is unavailable.
- Retain MIT and third-party notices in any combined distribution. Clearly identify which components the commercial terms cover.

Private storage and payment checks do not replace a license. Publishing paid code under the repository's MIT default would grant the MIT permissions for that code.

## Pro MCP boundary

The native operation service and shared library operations in this repository retain the MIT license. The `savenest-mcp` adapter, its MCP tool definitions, and its private source package are a separate Pro component. The official app can bundle that executable under the [Pro MCP component license](pro-mcp-license.md), while the public app continues to build and run without it. This does not relicense existing code or contributions.

MCP access in the official app requires an enabled connection, its granted permissions, and recently verified Pro access. The connection operates locally; subscription verification uses the existing account service. Publishing the shared operation service under MIT does not restrict the rights MIT already grants to it, and client-side access checks are not a promise that modified builds cannot bypass those checks.

The private adapter must not be included in a public source archive under this repository’s default MIT license. Official binary distributions carry the component license and required dependency notices. When Pro access ends, permission to use the proprietary component ends; the free core, MIT permissions, and local library use and export remain unaffected. See the [MCP guide](mcp.md) for 0.13.0 client compatibility and release verification.

## Contributions and future releases

Public contributions use MIT, as described in [CONTRIBUTING.md](../CONTRIBUTING.md). They do not become subject to paid resale restrictions simply because a commercial build uses them. Any separately contributed proprietary code needs explicit contribution terms for that component.

Each proprietary distribution must identify its covered components and rights holder and include the applicable component terms and dependency notices. Publishing those terms does not announce that the component has passed compatibility checks or been released.
