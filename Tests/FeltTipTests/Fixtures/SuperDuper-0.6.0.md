## Welcome to SuperDuper! v4.0 B0.6

Here’s the next update to SuperDuper! v4.0. This one’s mostly about polish, resilience, and fixing things that didn’t behave the way they should, thanks to your feedback, comments, complaints, and overall well intentioned whining.

### What’s new and improved

**Pause and Resume actually work now.** The button was there, but it didn’t do anything—click Pause and the copy kept right on going. It now genuinely pauses the running copy (finishing the current step first, so you’ll briefly see “Pausing…”) and resumes cleanly.

**If a drive gets erased or reformatted behind SuperDuper’s back, it now detects and heals more cases when possible.** This includes both sources and destinations.

**Bootable copies preserve more of the destination.** Erase-then-copy bootable backups now restore the destination’s Spotlight indexing state and its custom volume icon after the copy. This includes more than just **on** and **off**: individual path states are preserved as well. 

### Fixes

 - The **Preview Report** correctly disappears when you change a job’s settings, and no longer pops back a few seconds later showing a stale preview for the old settings.
 - **Renaming a job**: clicking anywhere outside the name field now saves the new name (you no longer have to press Return).
 - A job pointed at an unmounted bootable backup now correctly says the copy **preserves macOS**, instead of wrongly offering to “make it bootable.”
 - Onboarding now points you at the **correct, current** macOS System Settings locations for Full Disk Access and the background helper—Apple has moved these around over the years, and no doubt will again. Probably just after this is released.

### A little more polish

 - I've changed the internal panels to appear as sheets attached to the window, which look and act better than before.
 - The whole job is a drop target for a destination, so you don’t have to aim.
 - Virtually every bit of text has been reworked to be clearer: job descriptions; What's going to happen?; "no jobs yet" help; licensing; etc. No doubt some placeholder text remains somewhere, so if you see something, say something.

### Loose lips, etc.

Still Top Secret. You’re one of the few who’s seen how big these changes are, and I’d love the full extent to stay a surprise—**please keep it that way!**

Any feedback, comments, problems, loves, hates—pop them into your shared note, or send email.

Thanks, as always, for your help!

—Dave Nanian, Shirt 👕 Pocket
