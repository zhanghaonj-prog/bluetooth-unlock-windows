using BleProximityWake.Core.Presence;

namespace BleProximityWake.Agent.Configuration
{
    internal sealed class AgentSettings
    {
        internal const int CurrentSchemaVersion = 5;

        public int SchemaVersion { get; set; }

        public PresencePolicySet PresencePolicies { get; set; }

        public BleRuntimeSettings Ble { get; set; }

        public PresenceDetectionOptions Detection { get; set; }

        public NetworkSettings Network { get; set; }

        public SystemActionSettings Actions { get; set; }

        public AutoUnlockSettings AutoUnlock { get; set; }

        public static AgentSettings CreateDefaults()
        {
            return new AgentSettings
            {
                SchemaVersion = CurrentSchemaVersion,
                PresencePolicies = PresencePolicySet.CreateDefaults(),
                Ble = new BleRuntimeSettings(),
                Detection = new PresenceDetectionOptions
                {
                    PhoneEnabled = true
                },
                Network = new NetworkSettings(),
                Actions = new SystemActionSettings(),
                AutoUnlock = new AutoUnlockSettings()
            };
        }

        public void Validate()
        {
            if (SchemaVersion < 1 || SchemaVersion > CurrentSchemaVersion)
            {
                throw new System.InvalidOperationException("Unsupported agent settings schema version.");
            }

            if (PresencePolicies == null)
            {
                throw new System.InvalidOperationException("Presence policies are missing.");
            }

            PresencePolicies.Validate();
            if (Ble == null || Detection == null || Network == null ||
                Actions == null || AutoUnlock == null)
            {
                throw new System.InvalidOperationException(
                    "BLE, detection, and network settings are required.");
            }

            Ble.Validate();
            Detection.Validate();
            Network.Validate();
            Actions.Validate();
            AutoUnlock.Validate();
        }
    }
}
