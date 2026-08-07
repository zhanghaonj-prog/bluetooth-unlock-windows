using System;

namespace BleProximityWake.Core.Presence
{
    public static class PresenceDecisionEvaluator
    {
        public static PresenceDecision Evaluate(PresencePolicy policy, PresenceObservation observation)
        {
            if (policy == null)
            {
                throw new ArgumentNullException("policy");
            }

            if (observation == null)
            {
                throw new ArgumentNullException("observation");
            }

            policy.Validate("presence");

            bool watchRequired = policy.Mode == PresenceMode.WatchAndPhone;
            bool phoneRequired = true;
            bool watchSatisfied = !watchRequired ||
                (observation.WatchReady &&
                 (!policy.RequireFreshAfterResume || observation.WatchFreshAfterResume));
            bool phoneSatisfied = !phoneRequired ||
                (observation.PhoneReady &&
                 (!policy.RequireFreshAfterResume || observation.PhoneFreshAfterResume));
            bool ready = watchSatisfied && phoneSatisfied;

            return new PresenceDecision
            {
                Mode = policy.Mode,
                WatchRequired = watchRequired,
                PhoneRequired = phoneRequired,
                WatchSatisfied = watchSatisfied,
                PhoneSatisfied = phoneSatisfied,
                PresenceReady = ready,
                Reason = ready
                    ? "presence-ready"
                    : BuildFailureReason(watchSatisfied, phoneSatisfied)
            };
        }

        private static string BuildFailureReason(bool watchSatisfied, bool phoneSatisfied)
        {
            if (!watchSatisfied && !phoneSatisfied)
            {
                return "watch-and-phone-not-ready";
            }

            if (!watchSatisfied)
            {
                return "watch-not-ready";
            }

            return "phone-not-ready";
        }
    }
}
