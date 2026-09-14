# Application core idea

This document captures the product vision understood from our initial discussion. It is a concept document, not a final specification. It distinguishes agreed requirements from proposed interpretations and open decisions. It deliberately leaves implementation languages and technology choices out of scope.

## 1. Purpose

Build a broadly useful, decentralised application through which people can communicate, store and share information, collaborate, and participate in communities without depending on a central platform operator.

The ambition includes alternatives to services such as Reddit, Google Drive and file sharing, Google Maps and location sharing, wikis, web pages, instant messaging, and video calling. These experiences should belong to one coherent system, sharing identity, relationships, data ownership, permissions and provenance.

The distinguishing idea is an accountable friend-to-friend network: people interact through persistent identities recognised by their friends, and data carries a verifiable record of its attributed origin and its passage through the network.

The application should be useful enough for everyday adoption while preserving individual control. Safety, accountability, maintainability, battery life and performance are core design concerns.

## 2. Agreed foundations

- The network is decentralised and takes inspiration from RetroShare's friend-to-friend model.
- Each user has one persistent identity within their account, which can be used across multiple devices.
- Friends recognise that persistent identity. Real-world identity verification is not required at this stage.
- A future optional connection to real-world identity may be possible.
- Data should have a record of its origin and the chain of people through whom it has passed.
- Different kinds of data have different distribution needs, from private device synchronisation to widely shared community content.
- Desktop computers and Android are initial platform requirements.
- People should be able to run their own node without a mandatory central service.
- Hosting a node or service for several users is a possible future extension.
- Instant messaging, video calling and good plugin support belong in the broader vision.
- The implementation should minimise code we must maintain, be easy to understand and maintain, and support effective AI-assisted development.

## 3. Persistent identity and multiple devices

A user's identity belongs to them rather than to a particular installation, device or hosting provider. Friends should continue to recognise the same person when that person adds a phone, replaces a computer or changes where their node runs.

One user identity can authorise several devices. Devices act on behalf of that identity, while remaining distinguishable where necessary for security, synchronisation and accountability.

The intended experience is that users establish relationships with people, rather than separately befriending every device those people own.

Device enrolment, loss, removal and account recovery will need clear designs. A lost device should not require casually abandoning an established identity, and adding a device should not silently grant an attacker access. The exact recovery and authorisation arrangements remain undecided.

“One identity” describes the account model; it does not establish a global guarantee that a human cannot create another account. Preventing duplicate human identities is not an agreed requirement and cannot be assumed from persistent identifiers alone.

Real names and government documents are not prerequisites. Future real-world attestations should be an extension to the identity model, with their visibility and consequences explicitly defined.

## 4. Friend-to-friend relationships

Direct relationships between recognised identities form the foundation of the network. These relationships provide a basis for connecting, exchanging information and deciding what to accept or distribute.

Content may travel beyond its author's immediate friends through other participating people. This enables communities and publications to reach a broad audience without requiring a single central distribution platform.

Friendship should not automatically imply unrestricted access to a person's files, location, messages or devices. Trust has context: a person may be trusted as a contact without being authorised to read a private folder or administer a community.

The exact meaning of friend-to-friend routing is still open. In particular, we have not decided whether every payload must traverse friendship links, or whether authorised endpoints may establish direct connections after discovery through the network. This matters for calls, large transfers, privacy and resource use.

## 5. Origin and distribution provenance

Provenance is a central feature of the product, rather than optional metadata added by individual applications.

The desired user experience is that someone receiving an object can inspect who introduced or authored it, how it relates to earlier versions, and through which people it reached them. This should help people assess information, understand sharing and investigate misuse.

Examples include a community post retaining its author as it spreads, a shared file retaining its attributed source, and a wiki revision retaining responsibility for the change.

Several distinctions must be preserved:

- Authorship: an identity claims to have created content.
- Introduction: an identity brings externally obtained content into the network.
- Editing: an identity creates a new version or derived object.
- Deliberate sharing: an identity chooses to distribute an object to another audience.
- Automatic forwarding: a node transports or replicates content under its configured policies.
- Receipt: an identity or device acknowledges receiving something, if the design requires such acknowledgements.

These actions are not equivalent. Automatically transporting encrypted content should not be represented as endorsing or authoring it.

Distribution can branch, and a recipient can receive the same object along several paths. The conceptual history is therefore potentially a graph of handoffs and versions, even though an individual delivery may have a chain.

The security guarantee must be stated carefully. Recorded claims and handoffs can be made verifiable. They cannot prove that a statement is true, that an imported file's claimed creator is its real creator, or that nobody copied data outside the application. Colluding participants may also conceal off-protocol exchanges.

The requirement is to pursue strong, verifiable in-network provenance without claiming an impossible universal history of every copy. The precise completeness rules, rejection rules, retention policy and treatment of imported content remain to be designed.

## 6. Accountability with privacy

The application intentionally uses persistent, attributable identities. It does not require exposing all activity publicly.

A private conversation can have recognised participants and attributable messages while remaining private to those participants. Personal files can retain provenance without becoming visible to friends. Location sharing can be limited to a chosen audience.

Content visibility and provenance visibility both need explicit policies. Distribution histories can reveal relationships, group membership and behaviour even when the content is encrypted.

We have not yet decided who can inspect which parts of a forwarding history, or how much information intermediate participants must learn. Mandatory attribution should not silently become a globally readable social graph.

Accountability also needs understandable consequences and tools: the ability to refuse connections, block identities, control replication and govern shared spaces. Attribution alone does not prevent abuse.

## 7. Different audiences and sharing patterns

The same foundation must support several scopes of sharing:

- Personal: data kept on one device or synchronised across the user's devices.
- Explicit recipients: a message, file or location shared with selected people.
- Groups: data shared with a defined membership.
- Communities: posts and collaborative content distributed to interested participants.
- Broad publication: content intended to spread widely through willing participants.

These are conceptual use cases, not a final fixed permission hierarchy.

Sharing should be deliberate and understandable. Users need to know which audience can access an object and whether further distribution is allowed or expected.

Permission changes can govern future access and cooperative behaviour, but cannot guarantee erasure of plaintext already received by another person. The interface must make such limits understandable without overwhelming normal use.

## 8. Application experiences

### Personal storage and file sharing

Provide a personal drive-like experience, primarily synchronising between a user's own devices, with options to share files or folders more widely.

The broader design should consider offline access, changes made on different devices, version history, selective local storage and optional backup arrangements. These details are candidates for specification rather than settled behaviour.

Storage and availability must be visible: users should be able to understand where copies exist and whether content will be accessible while their devices are offline.

### Communities and discussion

Provide a Reddit-like experience for communities, posts and conversations that can spread beyond immediate friends.

Widely distributed content should retain attribution and provenance. Community governance, subscriptions, discovery, moderation and ranking need design; copying Reddit's exact voting or recommendation system is not an agreed requirement.

Broad distribution must work within the resources people are willing to contribute. It should not assume that every node stores or forwards every community.

### Instant messaging

Provide direct communication between persistent identities, usable across their devices. Group communication is a natural extension, with its exact scope still to be defined.

Delivery during offline periods, device synchronisation, retention and message history need explicit decisions. Private messaging must fit the identity and provenance model without exposing conversations to unrelated participants.

### Voice and video communication

Video calling is part of the vision, with voice communication a closely related experience. Calls require timely delivery and must fit the network's trust, routing and privacy rules.

Recording calls is not an agreed requirement. Provenance for persistent shared objects should not be interpreted as requiring permanent recordings or histories of every live media packet.

### Wikis and collaborative knowledge

Support knowledge spaces with attributable contributions and changes. Participants should be able to understand the origin and revision history of shared material.

Concurrent editing, conflict handling, editorial roles and publication rules remain open. Real-time document co-editing is a possible extension rather than a fully specified initial requirement.

### Web pages and publishing

Support publishing and accessing pages through the network, associated with persistent identities or shared spaces and distributed without a mandatory central host.

The allowed page format, active content, addressing, discovery and compatibility with ordinary web browsers remain undecided. Support for pages does not automatically imply unrestricted execution of code received from other users.

### Maps and location sharing

The ambition includes map-related utility and controlled location sharing. Users could share their location with chosen people or groups rather than relying entirely on a central platform.

The extent of the map product is not yet defined. Map display, shared places, geographic datasets, search, routing, navigation and live traffic are distinct capabilities; replacing the full scope of Google Maps should not be assumed to be an initial deliverable.

Location is particularly sensitive and power-intensive. Audience, update frequency, expiry and retention will need deliberate defaults.

### Plugins

Good plugin support should allow new utility to be added without continually expanding the core application.

Plugins should reuse common identity, sharing and provenance facilities. Their access to data, publishing actions, devices and network resources should be explicit and constrained.

The plugin model, installation process, distribution, compatibility policy and UI integration remain open. A plugin's authorship or signature does not by itself make its behaviour safe.

## 9. One coherent system

The applications should reinforce each other. A file could be shared in a conversation, referenced by a wiki or attached to a community post without losing its identity and provenance.

Cross-application use must still respect audience boundaries. Referencing a private file in a broad discussion should not silently publish its contents or grant new access.

Shared identity, permission, storage and provenance concepts should minimise duplicated behaviour and make the product understandable. Users should not have to learn unrelated sharing models for each feature.

## 10. Decentralisation and availability

People should be able to operate their own node and retain control of their identity and data. The system should not depend on a mandatory central account authority or a single organisation's continued operation.

Decentralisation does not make data automatically available. If all authorised copies are on offline devices, access may be unavailable until one returns.

Optional always-on personal nodes, willing storage peers or replaceable supporting services could improve availability. These are design possibilities, not yet selected service models. Their permissions and access to content must be explicit.

Serving several users from one server is a possible later extension. It must eventually distinguish operating infrastructure from controlling users' identities and private data; key custody and administrator powers remain undecided.

Disconnected use and later synchronisation are important design considerations for a network of intermittently connected devices. We have not promised immediate global consistency or delivery under all conditions.

## 11. Safety and community control

Safety includes protection against unauthorised access, compromised devices, malicious content, abusive identities and resource exhaustion.

Users should retain control over connections and the resources their devices contribute. Shared communities will need understandable governance and moderation arrangements.

Important areas for further design include blocking, membership changes, device revocation, storage and bandwidth limits, unwanted distribution, malicious plugins and deceptive provenance claims.

Trust should not be assumed to propagate without limit through friends of friends. Similarly, a widely distributed signed object should not gain unlimited storage, computation or attention merely because it is attributable.

A universal reputation score, global moderation authority and compulsory real-world identity verification are not agreed features.

## 12. Performance, battery life and usability

The product should be practical on everyday computers and Android phones. Phones should not have to behave like continuously active servers to participate meaningfully.

The design should consider different levels of participation based on connectivity, charging state, available storage and user preferences. Background synchronisation, forwarding and large transfers should have bounded costs.

Immediate communication, battery life and independence from external wakeup services can conflict. These tradeoffs need product decisions rather than being hidden in implementation details.

Users should be able to understand identity, sharing, availability and provenance without needing to understand the underlying networking or cryptography.

## 13. Maintainability and development principles

Minimise the code and integration machinery the project must own while retaining clear security boundaries and understandable behaviour.

Keep common rules in shared components so individual applications do not independently reinvent identity, permissions or provenance. Prefer explicit responsibilities and documented behaviour over clever abstractions.

The codebase should be approachable for both human and AI-assisted development. Clear specifications, consistent structure and meaningful checks are more important than reducing line count at the expense of clarity.

This is a long-term platform ambition. Maintainability includes being able to evolve the protocol and data formats while understanding compatibility with existing devices and stored content.

## 14. Open product decisions

1. Must every payload travel through friendship links, or can authorised endpoints communicate directly?
2. What exactly does a forwarding record attest to, and when is one required?
3. Which participants can inspect each part of a provenance history?
4. How are imported content, missing history and derived copies represented?
5. How are identities recovered and devices added or revoked?
6. How are groups, membership and sharing permissions represented to users?
7. How do communities discover content and govern moderation?
8. What availability promises can a user expect when devices are offline?
9. How should mobile delivery balance immediacy, battery use and optional external services?
10. What are the initial map and location features?
11. What may plugins access, execute and publish?
12. Which small set of user experiences should constitute the first release?

## 15. Candidate first demonstration

The following is a proposed way to validate the vision, not an agreed delivery plan:

- A person establishes an identity and adds a second device.
- Two people establish a recognised friendship.
- A private message and personal file synchronise as intended.
- A shared object passes through a third person with inspectable provenance.
- A simple community distributes posts to interested participants.
- Devices disconnect and reconnect without losing the relationship between identity, content and history.
- Users can inspect sharing scope, remove a device and limit resource use.

This would demonstrate the distinctive foundation before expanding into the full range of applications.
