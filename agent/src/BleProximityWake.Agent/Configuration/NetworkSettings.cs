namespace BleProximityWake.Agent.Configuration
{
    public sealed class NetworkSettings
    {
        public bool Enabled { get; set; } = true;

        public string[] AllowedProfileNames { get; set; } = new string[0];

        public string[] AllowedSsids { get; set; } = new string[0];

        public void Validate()
        {
            if (AllowedProfileNames == null || AllowedSsids == null)
            {
                throw new System.InvalidOperationException(
                    "Network whitelist arrays must not be null.");
            }
        }
    }
}
