# Standard workflow for every new agreement type

All future agreement implementations must support private draft, explicit admin assignment for read-only review, separate admin release for client signature, client signature, explicit admin review and countersignature, and an immutable final PDF with audit trail and hashes.

JP signature and company stamp must never be embedded in a base template or returned to clients before explicit final admin approval. Keep signing assets admin-only. Draft access is limited to the assigned recipient. Saving revised commercial drafts withdraws review access until the administrator shares again. Existing signed records remain immutable. Use server-side guards; hiding controls alone is insufficient.

Implemented for JVA, SPA, FCO, Commission Agreement and MCNDA. MCNDA uses draft_review and assigned states plus portal_mcnda_approvals for client-signed/final records.
