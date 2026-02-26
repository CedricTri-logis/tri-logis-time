"use client";

import * as React from "react";
import RPNInput from "react-phone-number-input";
import type { E164Number } from "libphonenumber-js";
import "react-phone-number-input/style.css";
import { cn } from "@/lib/utils";

const InputField = React.forwardRef<
  HTMLInputElement,
  React.ComponentProps<"input">
>(({ className, ...props }, ref) => (
  <input
    className={cn(
      "flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-base shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50 md:text-sm",
      className
    )}
    ref={ref}
    {...props}
  />
));
InputField.displayName = "InputField";

export interface PhoneInputProps {
  value?: string;
  onChange?: (value: string) => void;
  onBlur?: () => void;
  name?: string;
  className?: string;
  placeholder?: string;
  autoFocus?: boolean;
  disabled?: boolean;
}

function PhoneInput({
  className,
  onChange,
  value,
  ...props
}: PhoneInputProps) {
  return (
    <RPNInput
      international
      defaultCountry="CA"
      countryCallingCodeEditable={false}
      inputComponent={InputField}
      className={cn(
        "flex items-center gap-2 [&_.PhoneInputCountry]:flex [&_.PhoneInputCountry]:items-center [&_.PhoneInputCountry]:gap-1 [&_.PhoneInputCountryIcon--border]:shadow-none",
        className
      )}
      value={(value as E164Number) || undefined}
      onChange={(val?: E164Number) => onChange?.(val ?? "")}
      {...props}
    />
  );
}
PhoneInput.displayName = "PhoneInput";

export { PhoneInput };
