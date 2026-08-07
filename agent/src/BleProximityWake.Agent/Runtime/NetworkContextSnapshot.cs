namespace BleProximityWake.Agent.Runtime
{
    internal sealed class NetworkContextSnapshot
    {
        internal bool Allowed { get; set; }

        internal string Reason { get; set; }

        internal string[] ProfileNames { get; set; }

        internal string[] Ssids { get; set; }
    }
}
