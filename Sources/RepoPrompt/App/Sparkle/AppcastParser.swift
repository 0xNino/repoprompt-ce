//
//  AppcastParser.swift
//  RepoPrompt
//
//  Created by RepoPrompt Code Assistant on 2025-12-05.
//

import Foundation

/// Represents a single version entry from the appcast
struct AppcastVersion {
    let version: String
    let buildNumber: String?
    let title: String?
    let date: Date?
    let description: String?
    let releaseNotesURL: String?
    let downloadURL: String?
    let minimumSystemVersion: String?
    let minimumAutoupdateVersion: String?
    let installationType: String?
}

/// Immutable client state captured before detached appcast parsing so sibling
/// transition items can be filtered for eligibility off the main actor.
struct AppcastEligibilityContext: Equatable {
    let currentBuildNumber: String
    let osVersion: SparkleBuildVersion
}

/// Eligibility rules for a single appcast item. Constraints that are absent keep
/// the historical single-item feed behavior; constraints that are present but
/// malformed or unknown fail closed so a legacy client never advertises an
/// update it must not take.
enum AppcastItemEligibility {
    static let supportedInstallationTypes: Set<String> = ["application", "package"]

    static func isEligible(_ item: AppcastVersion, context: AppcastEligibilityContext) -> Bool {
        if let installationType = item.installationType {
            guard supportedInstallationTypes.contains(installationType) else { return false }
        }
        if let minimumSystemVersion = item.minimumSystemVersion {
            guard let required = SparkleBuildVersion(minimumSystemVersion),
                  required <= context.osVersion
            else { return false }
        }
        if let minimumAutoupdateVersion = item.minimumAutoupdateVersion {
            guard let required = SparkleBuildVersion(minimumAutoupdateVersion),
                  let currentBuild = SparkleBuildVersion(context.currentBuildNumber),
                  currentBuild >= required
            else { return false }
        }
        return true
    }
}

/// Parses Sparkle appcast.xml feeds to extract version information
final class AppcastParser: NSObject, XMLParserDelegate {
    // MARK: - Parsing State

    private var versions: [AppcastVersion] = []
    private var currentElement: String = ""
    private var currentVersion: String?
    private var currentBuildNumber: String?
    private var currentTitle: String?
    private var currentDate: Date?
    private var currentReleaseNotesURL: String?
    private var currentDownloadURL: String?
    private var currentMinimumSystemVersion: String?
    private var currentMinimumAutoupdateVersion: String?
    private var currentInstallationType: String?
    private var currentText: String = ""
    private var inItem = false

    /// Date formatter for pubDate parsing (RFC 2822 format)
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    // MARK: - Public API

    /// Parses appcast XML data and returns the newest version the client is
    /// eligible for, or nil if parsing fails or no item is eligible.
    func parse(data: Data, context: AppcastEligibilityContext) -> AppcastVersion? {
        Self.select(from: parseItems(data: data), context: context)
    }

    /// Parses every appcast item. Malformed XML fails the entire parse rather
    /// than returning a partial item list.
    func parseItems(data: Data) -> [AppcastVersion] {
        versions.removeAll()
        resetCurrentItem()

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false // Keep prefixes like "sparkle:"
        guard parser.parse() else { return [] }
        return versions
    }

    /// Filters items for eligibility first, then returns the update with the
    /// highest numeric Sparkle build, falling back to marketing-version
    /// comparison for legacy appcasts.
    static func select(
        from items: [AppcastVersion],
        context: AppcastEligibilityContext
    ) -> AppcastVersion? {
        items
            .filter { AppcastItemEligibility.isEligible($0, context: context) }
            .max { lhs, rhs in
                if let lhsBuild = lhs.buildNumber.flatMap(SparkleBuildVersion.init),
                   let rhsBuild = rhs.buildNumber.flatMap(SparkleBuildVersion.init)
                {
                    return lhsBuild < rhsBuild
                }
                if SparkleVersionComparison.isVersion(lhs.version, newerThan: rhs.version) { return false }
                return SparkleVersionComparison.isVersion(rhs.version, newerThan: lhs.version)
            }
    }

    // MARK: - Private Helpers

    private func resetCurrentItem() {
        currentVersion = nil
        currentBuildNumber = nil
        currentTitle = nil
        currentDate = nil
        currentReleaseNotesURL = nil
        currentDownloadURL = nil
        currentMinimumSystemVersion = nil
        currentMinimumAutoupdateVersion = nil
        currentInstallationType = nil
        currentText = ""
        inItem = false
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        switch elementName {
        case "item":
            inItem = true
            // Reset item-specific state but keep inItem = true
            currentVersion = nil
            currentBuildNumber = nil
            currentTitle = nil
            currentDate = nil
            currentReleaseNotesURL = nil
            currentDownloadURL = nil
            currentMinimumSystemVersion = nil
            currentMinimumAutoupdateVersion = nil
            currentInstallationType = nil

        case "enclosure":
            // Extract download URL and installation type from enclosure
            if inItem {
                currentDownloadURL = attributeDict["url"]
                currentInstallationType = attributeDict["sparkle:installationType"]
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmedText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "item":
            if inItem, let version = currentVersion, !version.isEmpty {
                let appcastVersion = AppcastVersion(
                    version: version,
                    buildNumber: currentBuildNumber,
                    title: currentTitle,
                    date: currentDate,
                    description: nil,
                    releaseNotesURL: currentReleaseNotesURL,
                    downloadURL: currentDownloadURL,
                    minimumSystemVersion: currentMinimumSystemVersion,
                    minimumAutoupdateVersion: currentMinimumAutoupdateVersion,
                    installationType: currentInstallationType
                )
                versions.append(appcastVersion)
            }
            inItem = false

        case "sparkle:shortVersionString":
            if inItem, !trimmedText.isEmpty {
                currentVersion = trimmedText
            }

        case "sparkle:version":
            if inItem, !trimmedText.isEmpty {
                currentBuildNumber = trimmedText
                // Use as version fallback if shortVersionString not present
                if currentVersion == nil {
                    currentVersion = trimmedText
                }
            }

        case "title":
            if inItem, !trimmedText.isEmpty {
                currentTitle = trimmedText
            }

        case "pubDate":
            if inItem, !trimmedText.isEmpty {
                currentDate = dateFormatter.date(from: trimmedText)
            }

        case "sparkle:releaseNotesLink":
            if inItem, !trimmedText.isEmpty {
                currentReleaseNotesURL = trimmedText
            }

        case "sparkle:minimumSystemVersion":
            if inItem, !trimmedText.isEmpty {
                currentMinimumSystemVersion = trimmedText
            }

        case "sparkle:minimumAutoupdateVersion":
            if inItem, !trimmedText.isEmpty {
                currentMinimumAutoupdateVersion = trimmedText
            }

        default:
            break
        }

        currentElement = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        print("[AppcastParser] Parse error: \(parseError)")
    }
}
