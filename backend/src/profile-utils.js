function computeProfileStatus(profile) {
  const missingFields = [];

  if (!profile.firstName || !String(profile.firstName).trim()) {
    missingFields.push("firstName");
  }
  if (!profile.lastName || !String(profile.lastName).trim()) {
    missingFields.push("lastName");
  }
  if (!profile.phoneNumber || !String(profile.phoneNumber).trim()) {
    missingFields.push("phoneNumber");
  }
  if (!profile.username || !String(profile.username).trim()) {
    missingFields.push("username");
  }

  return {
    isComplete: missingFields.length === 0,
    missingFields,
  };
}

function composeDisplayName(profile) {
  const parts = [
    profile.firstName,
    profile.middleName,
    profile.lastName,
  ]
    .map((value) => String(value || "").trim())
    .filter(Boolean);

  if (parts.length > 0) {
    return parts.join(" ");
  }

  return String(profile.displayName || "").trim();
}

function sanitizeProfile(profile = {}) {
  return {
    id: String(profile.id || ""),
    email: String(profile.email || ""),
    firstName: String(profile.firstName || ""),
    lastName: String(profile.lastName || ""),
    middleName: String(profile.middleName || ""),
    displayName: composeDisplayName(profile),
    username: String(profile.username || ""),
    phoneNumber: String(profile.phoneNumber || ""),
    countryCode:
      profile.countryCode === undefined || profile.countryCode === null
        ? null
        : String(profile.countryCode),
    countryName:
      profile.countryName === undefined || profile.countryName === null
        ? null
        : String(profile.countryName),
    city: String(profile.city || ""),
    photoUrl:
      profile.photoUrl === undefined || profile.photoUrl === null
        ? null
        : String(profile.photoUrl),
    isPhoneVerified: profile.isPhoneVerified === true,
    gender: String(profile.gender || "unknown"),
    maidenName: String(profile.maidenName || ""),
    birthDate:
      profile.birthDate === undefined || profile.birthDate === null
        ? null
        : String(profile.birthDate),
    createdAt:
      profile.createdAt === undefined || profile.createdAt === null
        ? null
        : String(profile.createdAt),
    updatedAt:
      profile.updatedAt === undefined || profile.updatedAt === null
        ? null
        : String(profile.updatedAt),
  };
}

module.exports = {
  computeProfileStatus,
  composeDisplayName,
  sanitizeProfile,
};
