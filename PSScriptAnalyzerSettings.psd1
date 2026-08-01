@{
    # Severities that fail tools/verify.ps1. Warnings are enforced except for the rules
    # excluded below, which are either wrong for this codebase or would require renaming
    # public-facing function names for no behavioural gain.
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # This app mutates monitor and process state constantly; ShouldProcess on every
        # such function would add confirmation plumbing to code paths that already have
        # their own explicit consent gates (risky VCP unlock, capability discovery,
        # optional helper toggles).
        'PSUseShouldProcessForStateChangingFunctions',

        # Nouns like Get-Monitors and Get-UserProfileFiles describe collections and are
        # part of the established vocabulary of this script.
        'PSUseSingularNouns',

        # Verbs such as Queue-VCPValue and Drain-DdcWriteResults read better than the
        # approved alternatives for a hardware write queue.
        'PSUseApprovedVerbs',

        # Progress and verification output is intentionally written to the host: these
        # are interactive tools, and the output stream is reserved for return values.
        'PSAvoidUsingWriteHost',

        # Best-effort cleanup around native handles, disposal, and optional integrations.
        # A failure to release something the app is already abandoning must not surface as
        # an error, and every path that a user needs to hear about reports through
        # Register-DdcDiagnostic or Update-Status instead.
        'PSAvoidUsingEmptyCatchBlock',

        # Fires on WPF event-handler signatures - param($sender, $eventArgs) - and on
        # scriptblock parameters that are consumed by the caller rather than the body.
        # The genuine case this rule catches here, a local named $profile shadowing the
        # automatic $PROFILE, has been renamed.
        'PSAvoidAssignmentToAutomaticVariable',
        'PSReviewUnusedParameter'
    )

    Rules = @{
        PSAvoidUsingCmdletAliases = @{
            Whitelist = @()
        }
    }
}
