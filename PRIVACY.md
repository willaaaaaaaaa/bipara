# Privacy

Bipara runs document and task logic locally. Translation sends the selected
document's bounded source units and neighboring source context to the configured
API endpoint. Selection analysis sends the selected unit and its existing
counterpart text. Hovering uses local mappings. Transmission acknowledgement is
scoped to the provider and destination origin; a custom Base URL changes the
destination. API use requires network access and may incur provider charges.

API keys are stored in configuration-scoped macOS Keychain items. They travel to
the bundled worker over local pipes and to the configured HTTPS endpoint as
authentication, outside model messages. Endpoint changes invalidate the saved
credential binding. Credentials, endpoint URLs, local configuration IDs and
display aliases are excluded from portable `.bipara` documents.

Explicitly saved documents contain original text, translation and task metadata
as local JSON; they are not encrypted by the application. Exports and clipboard
copies contain the text selected for those actions. No automatic session recovery
or cloud synchronization is provided. Close-without-saving can discard changes;
deleting a local file is controlled by the user and does not delete provider data.

The application has no analytics or account service. Model tracing and inherited
proxy/environment overrides are disabled in the production worker. Diagnostics
use bounded error codes and metadata, excluding raw prompts, keys and provider
response bodies. These are implementation contracts; current verification limits
are listed in [validation status](docs/validation.md).

Provider retention, training and billing policies are external to Bipara. Consult
the operator of the actual configured endpoint. Do not assume zero retention.
Development artifacts follow [repository boundaries](docs/repository-boundaries.md).
