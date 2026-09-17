i suggest, when we click on any equipment, we ned to have an equipment preview page. 

inside we present what we have for that equipment. 
we can edit delete or whatever. 

if the equipment have a owner assigned, we can remove from it ( with a  signing document - sent to him also - we are talkign as an hr now or admin or whoever can do that by th role ). then we can assignit to another one employee, with a document again. 

we need to keep history of them ( as service notes maybe ). 

leave page : https://personnel-hut4.vercel.app/leave

we have 2 tabs. let's make the tabs to get full width, and responsive. 

when https://personnel-hut4.vercel.app/leave here. we click any day of the calendar, on the right side the events for that day appears. that is not fking responsive at all. make it more responsive. also, when we have that cards on the side ( example who is away that day blabalbla ) , i can see at the top even if i press any day in the pass as working day : Working day
A normal day

yea, but this WAS workign day, so if not today, mark it red, color it, whatever. 


also , here we have 6 people are away
and for each of them a card. 

When the card is clicked, dialog to be opened with  detaield preview of that used ( or not ) vacation of that person. 



ALSO in the cards if we see this in the past cards : 
Thursday
10
September 2026

Working day
A normal day
4 people are away
Alina Gostovikj
annual · Hut4
31 Aug → 11 Sep · 9 working days
working day 8 of 9 · 1 left
“Imported from September 2026 leave calendar correction. · Imported from workbook: Sep 2026 (V day)”

i know it's calcualted on the selected day, what way it was  ( ex 9 from 10 , 8 from 10 ) . but from dotays perspective, it's full used vacation.. 



https://personnel-hut4.vercel.app/hiring
here, report a hide, only hr's need to be listed in the hiring manager dropdown. ( and that one with bigger roles than hr ) . 


https://personnel-hut4.vercel.app/directory when in people, the first selected tab shoyld be active, and not everyone. 

https://personnel-hut4.vercel.app/people/42dd912e-16c6-4bbc-abf3-77cbbdf17eb1
when we are here, all the cards that needs to get update ( edit mode ) are not responsive, when in edit or preview mode. review them. 


https://personnel-hut4.vercel.app/equipment
in the equipment sidebar page , we need filter ( search by equipment, ) filter by user, and so on. 


in the return equipment thing we build before, with the sign in, we need top open dialog instead of toogle down up that signing thing. opening dialog, standing int he viewport is much more usable from all perspectives

---
STATUS (17 Sep, updated as each lands)

DONE
- leave: tabs full width and responsive
- leave: day panel responsive (was cramped between 720 and 1080px)
- leave: past days in the past tense; "8 people were away"
- leave: a finished leave reads "taken in full", not "8 of 9 · 1 left"
- leave: clicking a person opens a dialog with both readings
- hiring: only HR and above in the hiring manager dropdown (3 of 42 at Synami)
- directory: opens on Active, not Everyone
- equipment: search by tag, inventory no., model, serial or holder; filter by
  who holds it (only people who hold something are listed)
- equipment return: signing is a centred dialog, not an inline expand

- person page: edit forms fold on their own width, not the window's
- equipment preview page: full detail, delete, and a service history

- equipment preview page: reassigning from the page itself. Built by
  generalising the return rather than copying it: equipment_returns became
  asset_handovers, which records an asset changing hands in either direction.
  The register's two-party rule, the signature pad and the forms are shared.
  On a reassign the outgoing holder does not sign — they are told, and their
  return form is filed while they still hold it, so equipment can still be
  recovered from somebody on leave or not answering.

LEFT
(nothing from the list above)

---
NEXT, in the order I would do them

1. Nobody has run the E2E suite against any of this. Everything built since
   the попис import — the register, self-service, signing, contract
   templates, the asset page, handovers — is verified by unit tests and by
   me driving the database, not by the browser suite. It is gated behind
   E2E_ALLOW_PRODUCTION for good reason; it wants a scratch project to run
   against, not the live one.

2. holder_note — 64 assets whose holder came from the books and was never
   matched to a person. A handover clears it, which is the right cure, but
   nothing prompts anyone to do it. A filter on the register for "named in
   the books, not matched to anyone" would let somebody work through them.

3. A handover that nobody signs sits awaiting forever, and the asset reads
   as still held by the old person. It wants an age: after a fortnight,
   show it as stale on the asset page and tell whoever started it. Not an
   auto-cancel — silently undoing a handover is worse than a stale row.

4. The signed scan comes back as a new version of the generated document,
   but nothing checks that it ever does. A handover accepted in the app with
   no signed copy filed is the same gap the return form has. A column on
   asset_handovers pointing at the document, and a line on the asset page
   when it is missing.

5. There is no page listing handovers. They are visible on the asset and on
   /me, which is right for the two people involved, but HR has no way to see
   "what moved this month" without opening assets one at a time. The data is
   there; it is one read-only page.

6. equipment_form_data prints everything a person holds, not the one thing
   the form is about. On a return of a single laptop the form lists the
   phone too. Correct for an offboarding, misleading for one handover.
