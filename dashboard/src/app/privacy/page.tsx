import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Politique de confidentialité - GPS Clock-In Tracker",
  description:
    "Politique de confidentialité de l'application mobile GPS Clock-In Tracker par Trilogis.",
};

export default function PrivacyPage() {
  return (
    <div className="min-h-screen bg-white">
      <div className="mx-auto max-w-3xl px-6 py-12">
        <h1 className="mb-2 text-3xl font-bold text-gray-900">
          Politique de confidentialité
        </h1>
        <p className="mb-8 text-sm text-gray-500">
          Dernière mise à jour : 13 février 2026
        </p>

        <div className="space-y-8 text-gray-700 leading-relaxed">
          <Section title="Aperçu">
            <p>
              GPS Clock-In Tracker (&laquo; l&apos;Application &raquo;) est une
              application de gestion de la main-d&apos;oeuvre développée par
              Trilogis. Cette politique de confidentialité explique comment nous
              collectons, utilisons et protégeons vos données personnelles
              lorsque vous utilisez l&apos;Application.
            </p>
          </Section>

          <Section title="Données que nous collectons">
            <h3 className="mt-4 mb-2 font-semibold text-gray-900">
              1. Données de localisation
            </h3>
            <ul className="list-disc space-y-1 pl-6">
              <li>
                Les coordonnées GPS précises sont collectées lorsque vous
                pointez à l&apos;arrivée, au départ, et de façon continue
                pendant les quarts de travail actifs.
              </li>
              <li>
                La localisation en arrière-plan est collectée pendant qu&apos;un
                quart de travail est actif, même lorsque l&apos;Application est
                minimisée ou que l&apos;écran est éteint. Cela est nécessaire
                pour vérifier la présence au travail et générer les relevés
                d&apos;itinéraire des quarts.
              </li>
              <li>
                Les données de localisation sont{" "}
                <strong>
                  uniquement collectées pendant les quarts de travail actifs
                </strong>
                . Aucune donnée de localisation n&apos;est collectée lorsque
                vous n&apos;êtes pas pointé.
              </li>
            </ul>

            <h3 className="mt-4 mb-2 font-semibold text-gray-900">
              2. Informations personnelles
            </h3>
            <ul className="list-disc space-y-1 pl-6">
              <li>
                Nom complet et numéro d&apos;employé (fournis par votre
                employeur)
              </li>
              <li>
                Adresse courriel (utilisée pour l&apos;authentification)
              </li>
              <li>
                Rôle au sein de votre organisation (employé, gestionnaire,
                administrateur)
              </li>
            </ul>

            <h3 className="mt-4 mb-2 font-semibold text-gray-900">
              3. Données de la caméra
            </h3>
            <ul className="list-disc space-y-1 pl-6">
              <li>
                La caméra est utilisée uniquement pour scanner les codes QR
                lors de l&apos;enregistrement et du départ des sessions de
                ménage.
              </li>
              <li>
                Aucune photo ni vidéo n&apos;est capturée, stockée ou
                transmise. Le flux de la caméra est traité en temps réel
                uniquement pour la détection de codes QR.
              </li>
            </ul>

            <h3 className="mt-4 mb-2 font-semibold text-gray-900">
              4. Informations sur l&apos;appareil
            </h3>
            <ul className="list-disc space-y-1 pl-6">
              <li>Métriques de précision GPS</li>
              <li>
                État du service de localisation de l&apos;appareil
                (activé/désactivé)
              </li>
              <li>
                État de la connectivité réseau (en ligne/hors ligne)
              </li>
            </ul>
          </Section>

          <Section title="Comment nous utilisons vos données">
            <div className="overflow-x-auto">
              <table className="w-full text-sm border-collapse">
                <thead>
                  <tr className="border-b border-gray-200">
                    <th className="py-2 pr-4 text-left font-semibold text-gray-900">
                      Données
                    </th>
                    <th className="py-2 text-left font-semibold text-gray-900">
                      Utilisation
                    </th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-100">
                  <tr>
                    <td className="py-2 pr-4">
                      Localisation GPS pendant les quarts
                    </td>
                    <td className="py-2">
                      Vérifier la présence au travail et la localisation ;
                      générer les relevés d&apos;itinéraire des quarts pour
                      examen par l&apos;employeur
                    </td>
                  </tr>
                  <tr>
                    <td className="py-2 pr-4">
                      Localisation en arrière-plan
                    </td>
                    <td className="py-2">
                      Maintenir la vérification continue de la localisation
                      pendant les quarts de travail actifs
                    </td>
                  </tr>
                  <tr>
                    <td className="py-2 pr-4">
                      Nom et numéro d&apos;employé
                    </td>
                    <td className="py-2">
                      Vous identifier au sein du système de gestion de la
                      main-d&apos;oeuvre de votre organisation
                    </td>
                  </tr>
                  <tr>
                    <td className="py-2 pr-4">Courriel</td>
                    <td className="py-2">
                      Authentification du compte et récupération du mot de passe
                    </td>
                  </tr>
                  <tr>
                    <td className="py-2 pr-4">Scans de codes QR</td>
                    <td className="py-2">
                      Enregistrer les arrivées et départs des sessions de ménage
                      dans des chambres et studios spécifiques
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </Section>

          <Section title="Stockage et sécurité des données">
            <ul className="list-disc space-y-1 pl-6">
              <li>
                <strong>Stockage infonuagique :</strong> Les données sont
                stockées de manière sécurisée sur Supabase (PostgreSQL) avec des
                politiques de sécurité au niveau des lignes.
              </li>
              <li>
                <strong>Stockage local :</strong> Les données hors ligne sont
                stockées sur l&apos;appareil à l&apos;aide de SQLCipher (base de
                données SQLite chiffrée AES-256).
              </li>
              <li>
                <strong>Les jetons d&apos;authentification</strong> sont stockés
                à l&apos;aide du stockage sécurisé de la plateforme (Android
                Keystore / iOS Keychain).
              </li>
              <li>
                Toutes les communications réseau utilisent le chiffrement
                HTTPS/TLS.
              </li>
            </ul>
          </Section>

          <Section title="Partage des données">
            <ul className="list-disc space-y-1 pl-6">
              <li>
                Vos données sont accessibles aux gestionnaires et
                administrateurs autorisés de votre employeur au sein de
                l&apos;Application à des fins de gestion de la
                main-d&apos;oeuvre.
              </li>
              <li>
                Nous ne vendons, ne louons et ne partageons{" "}
                <strong>pas</strong> vos données personnelles avec des tiers à
                des fins de publicité ou de marketing.
              </li>
              <li>
                Nous ne partageons <strong>pas</strong> les données de
                localisation avec un tiers en dehors de l&apos;organisation de
                votre employeur.
              </li>
            </ul>
          </Section>

          <Section title="Conservation des données">
            <ul className="list-disc space-y-1 pl-6">
              <li>
                Les données de quarts de travail et de localisation sont
                conservées tant que votre relation d&apos;emploi avec votre
                employeur est active, ou selon les exigences des lois du travail
                applicables.
              </li>
              <li>
                Vous pouvez demander la suppression de vos données en
                communiquant avec votre employeur ou directement avec Trilogis.
              </li>
            </ul>
          </Section>

          <Section title="Vos droits">
            <p>
              Selon votre juridiction, vous pouvez avoir le droit de :
            </p>
            <ul className="list-disc space-y-1 pl-6">
              <li>
                Accéder aux données personnelles que nous détenons à votre sujet
              </li>
              <li>Demander la correction de données inexactes</li>
              <li>Demander la suppression de vos données</li>
              <li>Retirer votre consentement à la collecte de données</li>
              <li>
                Recevoir une copie de vos données dans un format portable
              </li>
            </ul>
            <p className="mt-2">
              Pour exercer l&apos;un de ces droits, communiquez avec nous à
              l&apos;adresse ci-dessous.
            </p>
          </Section>

          <Section title="Divulgation de la localisation en arrière-plan">
            <p>
              Cette Application collecte des données de localisation en
              arrière-plan{" "}
              <strong>
                uniquement pendant les quarts de travail actifs
              </strong>{" "}
              afin de permettre la vérification continue de la présence. Le
              suivi de la localisation en arrière-plan :
            </p>
            <ul className="list-disc space-y-1 pl-6">
              <li>
                <strong>Commence</strong> lorsque vous pointez à l&apos;arrivée
                d&apos;un quart de travail
              </li>
              <li>
                <strong>S&apos;arrête</strong> lorsque vous pointez au départ ou
                que le quart se termine
              </li>
              <li>
                N&apos;est <strong>jamais actif</strong> en dehors des quarts de
                travail
              </li>
              <li>
                Est indiqué par une{" "}
                <strong>notification persistante</strong> sur votre appareil
                lorsqu&apos;il est actif
              </li>
            </ul>
            <p className="mt-2">
              Sans l&apos;accès à la localisation en arrière-plan,
              l&apos;Application ne peut pas vérifier votre présence au travail
              lorsque l&apos;écran est éteint, ce qui est une exigence
              fondamentale du système de gestion de la main-d&apos;oeuvre.
            </p>
          </Section>

          <Section title="Confidentialité des enfants">
            <p>
              Cette Application est destinée à être utilisée uniquement par des
              adultes employés. Nous ne collectons pas sciemment de données
              auprès de personnes de moins de 16 ans.
            </p>
          </Section>

          <Section title="Modifications de cette politique">
            <p>
              Nous pouvons mettre à jour cette politique de confidentialité de
              temps à autre. Nous informerons les utilisateurs de tout
              changement important par l&apos;intermédiaire de
              l&apos;Application ou par courriel.
            </p>
          </Section>

          <Section title="Nous contacter">
            <p>
              <strong>Trilogis</strong>
              <br />
              Courriel :{" "}
              <a
                href="mailto:cedric@trilogis.ca"
                className="text-blue-600 underline hover:text-blue-800"
              >
                cedric@trilogis.ca
              </a>
              <br />
              Site web :{" "}
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
              Si vous avez des questions ou des préoccupations concernant cette
              politique de confidentialité ou vos données, veuillez communiquer
              avec nous à l&apos;adresse courriel ci-dessus.
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
