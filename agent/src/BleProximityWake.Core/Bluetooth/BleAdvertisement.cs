using System;
using System.Collections.Generic;

namespace BleProximityWake.Core.Bluetooth
{
    public sealed class BleAdvertisement
    {
        public string Address { get; set; }

        public string LocalName { get; set; }

        public int Rssi { get; set; }

        public DateTime TimestampUtc { get; set; }

        public IList<string> ManufacturerData { get; set; } = new List<string>();

        public IList<string> ServiceUuids { get; set; } = new List<string>();
    }
}
