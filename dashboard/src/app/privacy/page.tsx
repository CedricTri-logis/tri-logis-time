import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Privacy Policy - GPS Clock-In Tracker",
  description:
    "Privacy policy for the GPS Clock-In Tracker mobile application by Trilogis.",
};

export default function PrivacyPage() {
  return (
    <div className="min-h-screen bg-white">
      <div className="mx-auto max-w-3xl px-6 py-12">
        <h1 className="mb-2 text-3xl font-bold text-gray-900">
          Privacy Policy
        </h1>
        <p className="mb-8 text-sm text-gray-500">
          Last updated: February 13, 2026
        </p>

        <div className="space-y-8 text-gray-700 leading-relaxed">
          <Section title="Overview">
            <p>
              GPS Clock-In Tracker (&quot;the App&quot;) is a workforce
              management application developed by Trilogis. This privacy policy
              explains how we collect, use, and protect your personal data when
              you use the App.
            </p>
          </Section>

          <Section title="Data We Collect">
            <h3 className="mt-4 mb-2 font-semibold text-gray-900">
              1. Location Data
            </h3>
            <ul className="list-disc space-y-1 pl-6">
              <li>
                Precise GPS coordinates are collected when you clock in, clock
                out, and continuously during active shifts.
              </li>
              <li>
                Background location is collected while a shift is active, even
                when the App is minimized or the screen is off. This is required
                to verify work attendance and generate shift route records.
              </li>
              <li>
                Location data is <strong>only collected during active shifts</strong>.
                No location data is collected when you are not clocked in.
              </li>
            </ul>

            <h3 className="mt-4 mb-2 font-semibold text-gray-900">
              2. Personal Information
            </h3>
            <ul className="list-disc space-y-1 pl-6">
              <li>Full name and employee ID (provided by your employer)</li>
              <li>Email address (used for authentication)</li>
              <li>Role within your organization (employee, manager, admin)</li>
            </ul>

            <h3 className="mt-4 mb-2 font-semibold text-gray-900">
              3. Camera Data
            </h3>
            <ul className="list-disc space-y-1 pl-6">
              <li>
                The camera is used solely to scan QR codes for cleaning session
                check-in and check-out.
              </li>
              <li>
                No photos or videos are captured, stored, or transmitted. The
                camera feed is processed in real-time for QR code detection only.
              </li>
            </ul>

            <h3 className="mt-4 mb-2 font-semibold text-gray-900">
              4. Device Information
            </h3>
            <ul className="list-disc space-y-1 pl-6">
              <li>GPS accuracy metrics</li>
              <li>Device location service status (enabled/disabled)</li>
              <li>Network connectivity status (online/offline)</li>
            </ul>
          </Section>

          <Section title="How We Use Your Data">
            <div className="overflow-x-auto">
              <table className="w-full text-sm border-collapse">
                <thead>
                  <tr className="border-b border-gray-200">
                    <th className="py-2 pr-4 text-left font-semibold text-gray-900">
                      Data
                    </th>
                    <th className="py-2 text-left font-semibold text-gray-900">
                      Purpose
                    </th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-100">
                  <tr>
                    <td className="py-2 pr-4">GPS location during shifts</td>
                    <td className="py-2">
                      Verify work attendance and location; generate shift route
                      records for employer review
                    </td>
                  </tr>
                  <tr>
                    <td className="py-2 pr-4">Background location</td>
                    <td className="py-2">
                      Maintain continuous location verification during active
                      shifts
                    </td>
                  </tr>
                  <tr>
                    <td className="py-2 pr-4">Name and employee ID</td>
                    <td className="py-2">
                      Identify you within your organization&apos;s workforce
                      management system
                    </td>
                  </tr>
                  <tr>
                    <td className="py-2 pr-4">Email</td>
                    <td className="py-2">
                      Account authentication and password recovery
                    </td>
                  </tr>
                  <tr>
                    <td className="py-2 pr-4">QR code scans</td>
                    <td className="py-2">
                      Record cleaning session check-ins and check-outs at
                      specific rooms and studios
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </Section>

          <Section title="Data Storage and Security">
            <ul className="list-disc space-y-1 pl-6">
              <li>
                <strong>Cloud storage:</strong> Data is stored securely on
                Supabase (PostgreSQL) with row-level security policies.
              </li>
              <li>
                <strong>Local storage:</strong> Offline data is stored on-device
                using SQLCipher (AES-256 encrypted SQLite database).
              </li>
              <li>
                <strong>Authentication tokens</strong> are stored using
                platform-secure storage (Android Keystore / iOS Keychain).
              </li>
              <li>
                All network communication uses HTTPS/TLS encryption.
              </li>
            </ul>
          </Section>

          <Section title="Data Sharing">
            <ul className="list-disc space-y-1 pl-6">
              <li>
                Your data is accessible to your employer&apos;s authorized
                managers and administrators within the App for workforce
                management purposes.
              </li>
              <li>
                We do <strong>not</strong> sell, rent, or share your personal
                data with third parties for advertising or marketing purposes.
              </li>
              <li>
                We do <strong>not</strong> share location data with any third
                party outside of your employer&apos;s organization.
              </li>
            </ul>
          </Section>

          <Section title="Data Retention">
            <ul className="list-disc space-y-1 pl-6">
              <li>
                Shift and location data is retained as long as your employment
                relationship with your employer is active, or as required by
                applicable labor laws.
              </li>
              <li>
                You may request deletion of your data by contacting your
                employer or Trilogis directly.
              </li>
            </ul>
          </Section>

          <Section title="Your Rights">
            <p>
              Depending on your jurisdiction, you may have the right to:
            </p>
            <ul className="list-disc space-y-1 pl-6">
              <li>Access the personal data we hold about you</li>
              <li>Request correction of inaccurate data</li>
              <li>Request deletion of your data</li>
              <li>Withdraw consent for data collection</li>
              <li>Receive a copy of your data in a portable format</li>
            </ul>
            <p className="mt-2">
              To exercise any of these rights, contact us at the address below.
            </p>
          </Section>

          <Section title="Background Location Disclosure">
            <p>
              This App collects location data in the background{" "}
              <strong>only during active work shifts</strong> to enable
              continuous attendance verification. Background location tracking:
            </p>
            <ul className="list-disc space-y-1 pl-6">
              <li>
                <strong>Starts</strong> when you clock in to a shift
              </li>
              <li>
                <strong>Stops</strong> when you clock out or the shift ends
              </li>
              <li>
                Is <strong>never active</strong> outside of work shifts
              </li>
              <li>
                Is indicated by a <strong>persistent notification</strong> on
                your device while active
              </li>
            </ul>
            <p className="mt-2">
              Without background location access, the App cannot verify your
              work attendance while the screen is off, which is a core
              requirement of the workforce management system.
            </p>
          </Section>

          <Section title="Children&apos;s Privacy">
            <p>
              This App is intended for use by employed adults only. We do not
              knowingly collect data from anyone under the age of 16.
            </p>
          </Section>

          <Section title="Changes to This Policy">
            <p>
              We may update this privacy policy from time to time. We will
              notify users of material changes through the App or via email.
            </p>
          </Section>

          <Section title="Contact Us">
            <p>
              <strong>Trilogis</strong>
              <br />
              Email:{" "}
              <a
                href="mailto:cedric@trilogis.ca"
                className="text-blue-600 underline hover:text-blue-800"
              >
                cedric@trilogis.ca
              </a>
              <br />
              Website:{" "}
              <a
                href="https://trilogis.ca"
                className="text-blue-600 underline hover:text-blue-800"
                target="_blank"
                rel="noopener noreferrer"
              >
                trilogis.ca
              </a>
            </p>
            <p className="mt-2">
              If you have questions or concerns about this privacy policy or
              your data, please contact us at the email address above.
            </p>
          </Section>
        </div>
      </div>
    </div>
  );
}

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section>
      <h2 className="mb-3 text-xl font-semibold text-gray-900">{title}</h2>
      {children}
    </section>
  );
}
