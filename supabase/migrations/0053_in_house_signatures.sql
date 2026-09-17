-- 0053_in_house_signatures.sql
-- Signing, in the app, without a signing service.
--
-- The alternatives were a paid API (SignWell: 25 documents a month, then $0.66
-- each) or a self-hosted one (OpenSign: free, but wants Docker, its own
-- MongoDB and a server to live on — neither Vercel nor Supabase can host it).
-- For handing a laptop back, both are more machinery than the job needs.
--
-- So the signature is made here: the person types their name, which renders in
-- a script face, or draws it, which arrives as a PNG data URL. The server
-- stamps that onto the return form with pdfmake, which already renders these
-- documents.
--
-- The picture is the smallest part of it. What makes a signature worth anything
-- afterwards is being able to say who signed, when, from where, and that the
-- document has not changed since — so all of that is recorded beside it, along
-- with the exact sentence the person agreed to. A cursive image proves nothing
-- on its own; a statement plus an audit trail is the evidence.
--
-- This is a SIMPLE electronic signature. It suits equipment, where both parties
-- are employees and the question is whether the thing came back. It is NOT
-- sufficient for an employment contract, which under EU/MK rules wants a
-- qualified signature from an accredited provider. Do not reuse this table for
-- one without taking advice first.

create type public.signature_method as enum ('typed', 'drawn');

create table public.signatures (
  id uuid primary key default gen_random_uuid(),
  -- what was signed
  subject_type text not null,              -- 'equipment_return', and whatever comes next
  subject_id uuid not null,
  -- who signed, and as what
  person_id uuid not null references public.people(id),
  signed_name text not null,               -- as they typed it, which may not match their record
  capacity text not null,                  -- 'the person returning it', 'for <Company>'
  statement text not null,                 -- the exact sentence they agreed to
  -- the mark itself
  method public.signature_method not null,
  image text,                              -- PNG data URL when drawn; null when typed
  -- the part that actually carries weight
  signed_at timestamptz not null default now(),
  signed_ip text,
  user_agent text,
  document_sha256 text,                    -- the form as it stood when they signed it
  created_at timestamptz not null default now()
);
create index signatures_subject_idx on public.signatures (subject_type, subject_id);
-- One signature per person per thing: signing twice is amending, not signing.
create unique index one_signature_per_person on public.signatures (subject_type, subject_id, person_id);

alter table public.signatures enable row level security;

-- You may read a signature on something you can already see. The equipment
-- return's own policy decides that, so this defers to it rather than repeating
-- its rules.
create policy sel on public.signatures for select to authenticated
  using (
    app.is_self(person_id)
    or exists (
      select 1 from public.equipment_returns r
      where subject_type = 'equipment_return' and r.id = subject_id
        and (app.is_self(r.person_id) or app.is_self(r.hr_person_id) or app.can_work_asset(r.company_id, 'it.view'))
    )
  );

-- Only you can sign as you. Nothing else may write here at all: a signature
-- someone else can create for you is not a signature.
create policy ins on public.signatures for insert to authenticated
  with check (app.is_self(person_id));

-- A signature is never edited or withdrawn. A mistake is corrected by a new
-- document, the way it would be on paper.
comment on table public.signatures is
  'Simple electronic signatures made in the app. Never updated, never deleted — correct by re-signing a new document.';
