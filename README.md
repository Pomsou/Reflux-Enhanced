# Reflux-Enhanced
Lightweight tool designed to take complete snapshots of your UI configuration. (saved variables) WoW Addon

Reviving Reflux for Midnight!
(Addon originally created by moonfann)
 

Reflux Enhanced is a powerful, lightweight tool designed to take complete snapshots of your UI configuration. Unlike standard profile managers that only handle settings, Reflux Enhanced captures both your addon settings and your enabled addon list, allowing you to switch between completely different UI environments (e.g., "Raid" vs "PvP" or "Minimalist") with a simple command. Addon saves ACE3 DB, _CONFIG, _DATA including some tricky Addons DB.

Reflux Enhanced does not save your profile from Edit Mode from Blizzard, too many taints.
📖 How to Use

Reflux Enhanced uses a simple slash command workflow.

## Saving a Profile

Configure your UI exactly how you want it (enable specific addons, move frames, change settings). Then, take a snapshot:

/reflux save [ProfileName]


Example: /reflux save Main
## Switching Profiles

To switch to a saved profile:

/reflux switch [ProfileName]

    If your addons match: Reflux Enhanced will immediately inject the settings, switch profiles, and reload your UI.
    If addons mismatch: It will stop and warn you: "ERROR: Addon mismatch detected! Type /reflux addons [ProfileName] first."

## Syncing Addons (If Mismatch)

If you are missing required addons for a profile, run:

/reflux addons [ProfileName]

 

This will automatically Enable/Disable the necessary addons to match the saved profile and reload the UI. Once reloaded, simply run the switch command again to finish loading the settings.

💡 Example Workflow: Loading profile on Alts 
 

1. You already have a UI that you are comfortable using with all your chars:

 /reflux save Main

Reflux will snapshot all the SavedVariables including those character specific and make them globally available through the profile and save the addon list as well.

2. Switch to your other alt/new character and load those variables:

/reflux switch Main

+ if the addons loaded are similar to the profile saved, reflux switch will load all the saved variables to that character directly.

+ if the addons loaded are different then the active addons, reflux switch will display a Warning Message saying that some addons needs to be enabled/disabled and it recommends to do:

/reflux addons Main

After that you can do /reflux switch to load those variables.

If you are already using another addon manager like Simple Addon Manager (SAM) to load your addon profiles, you can use reflux to just load the saved variables from those addons to different character and still have a warning in case the addon list is different!

OR if you can want different configurations of the same addons depending on the purpose (Raid, M+, PvP, etc). you can still use /reflux save an /reflux switch to those scenarios

 
📜 Command List

    /reflux save <name> - Creates a snapshot of current settings and enabled addons.
    /reflux switch <name> - Restores settings. Checks for addon mismatches first.
    /reflux addons <name> - Syncs enabled/disabled addons to match the profile (requires reload).
    /reflux list - Lists all saved profiles.
    /reflux delete <name> - Deletes a profile.
